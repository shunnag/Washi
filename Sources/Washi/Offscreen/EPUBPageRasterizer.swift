import AppKit
import WebKit

/// 固定レイアウトページを画面外でラスタライズする。
/// WKWebView はウインドウ外では描画が止まるため、画面外の枠なし
/// ウインドウ(一度も表示しない)に載せてスナップショットを取得する
/// (macOS で動作が実証された唯一の方法)。読み込みは1ページずつ
/// 直列に行う。
///
/// Offscreen rasterizer for fixed-layout pages.
/// A WKWebView stops rendering while it is outside a window, so we place it in
/// an offscreen borderless window (never shown) and take a snapshot from there
/// (the only approach proven to work on macOS). Loads are serialized one page
/// at a time.
///
/// 注意: 画像1枚だけのページは EPUBPublication.fixedLayoutInfo の
/// simpleImagePath から画像を直接デコードする方が高速かつ高画質。
/// このクラスはテキストと SVG を合成する複雑な FXL ページの
/// フォールバックとして使う。
///
/// Note: for a "single image only" page, decoding the image directly from
/// EPUBPublication.fixedLayoutInfo's simpleImagePath is faster and higher
/// quality. This class is the fallback for complex FXL pages that composite
/// text and SVG.
@MainActor
public final class EPUBPageRasterizer {
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler
    private let allowsScriptedContent: Bool
    private let host = EPUBOffscreenWebViewHost()
    // Washi-cfm: テストから画面外ウインドウの寿命を弱参照で観測する。
    var window: NSWindow? { host.window }
    var webView: WKWebView? { host.webView }
    // Washi-cfm: 描画中の停止箇所を調べる時刻だけを残し、WebView は保持しない。
    struct RenderTrace {
        var prepared: ContinuousClock.Instant?
        var didFinish: ContinuousClock.Instant?
        var readinessEnd: ContinuousClock.Instant?
        var snapshotEnd: ContinuousClock.Instant?
        var readinessTimedOut: Bool?
    }
    private(set) var lastRenderTrace = RenderTrace()
    /// cooViewer-oxr.68: 所有するサムネイルレンダラのアイドル診断用。
    var hasLiveWebView: Bool { host.hasLiveWebView }
    /// 直列化: 直前の要求が終わるまで次を待たせる
    private let queue = EPUBOffscreenJobQueue()
    private let idleTimerScheduler: EPUBOffscreenIdleReleaseTimer.Scheduler
    /// `idleReleaseInterval` が nil の間は nil(予約しない = 従来の寿命)。
    private var idleReleaseTimer: EPUBOffscreenIdleReleaseTimer?
    /// FIFO 待ちも含む進行中の要求数。0 になるまでアイドル解放しない。
    private var pendingRenderCount = 0

    /// 最後の描画要求が終わってから、オフスクリーンリソース(不可視 NSWindow と
    /// WebContent プロセス)を解放するまでのアイドル時間。既定の nil は従来どおり
    /// ``invalidate()`` まで保持する。描画中と FIFO で要求が待っている間は解放せず、
    /// 解放後の次の `renderPage` は初回と同じ経路で作り直す。実行中に変えると
    /// アイドル期限を予約し直し、0 以下は待機なしの解放を予約する。
    ///
    /// Idle time, measured from when the last render request finishes, after
    /// which the offscreen resources (the invisible NSWindow and the WebContent
    /// process) are released. The default nil keeps them until ``invalidate()``,
    /// as before. Nothing is released during a render or while requests wait in
    /// the FIFO; the next `renderPage` after a release rebuilds them exactly like
    /// a first render. Changing the value at run time restarts the idle
    /// deadline, and nonpositive values schedule an immediate release.
    public var idleReleaseInterval: Duration? {
        didSet {
            // 旧タイマの世代ガードは旧インスタンスのものなので、差し替える前に
            // その予約を止める(描画中に古い期限が発火して解放しないように)。
            idleReleaseTimer?.cancel()
            idleReleaseTimer = idleReleaseInterval.map {
                EPUBOffscreenIdleReleaseTimer(interval: max(.zero, $0),
                                              scheduler: idleTimerScheduler)
            }
            scheduleIdleReleaseIfNeeded()
        }
    }

    /// 固定レイアウトページのラスタライズ中に発生するエラー。
    ///
    /// An error raised while rasterizing a fixed-layout page.
    public enum RasterizeError: Error, Sendable, Equatable, LocalizedError {
        /// ページの文書を読み込めなかったか、読み込みが完了する前に
        /// ラスタライザが無効化された。
        ///
        /// The page's document could not be loaded (or the rasterizer was
        /// invalidated before it loaded).
        case loadFailed
        /// 画面外の Web ビューからスナップショット画像を取得できなかった。
        ///
        /// The offscreen web view produced no snapshot image.
        case snapshotFailed

        public var errorDescription: String? {
            switch self {
            case .loadFailed: return "The page could not be loaded for rendering."
            case .snapshotFailed: return "The page could not be captured as an image."
            }
        }
    }

    /// 著者スクリプトを無効にしたラスタライザを作る。
    ///
    /// Creates a rasterizer with author scripts disabled.
    public convenience init(publication: EPUBPublication) {
        self.init(publication: publication, allowsScriptedContent: false)
    }

    /// 画面外のページで著者スクリプトを実行できるかを指定して、
    /// ラスタライザを作る。
    ///
    /// Creates a rasterizer and chooses whether author scripts may run in the
    /// offscreen page.
    public convenience init(publication: EPUBPublication, allowsScriptedContent: Bool) {
        self.init(publication: publication, allowsScriptedContent: allowsScriptedContent,
                  idleTimerScheduler: EPUBOffscreenIdleReleaseTimer.continuousScheduler)
    }

    /// テスト用: アイドル解放の期限を実時間なしで進める scheduler を差し込む。
    init(
        publication: EPUBPublication, allowsScriptedContent: Bool,
        idleTimerScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler
    ) {
        self.publication = publication
        self.allowsScriptedContent = allowsScriptedContent
        self.schemeHandler = EPUBSchemeHandler(
            publication: publication, allowsScripts: allowsScriptedContent)
        self.idleTimerScheduler = idleTimerScheduler
    }

    /// invalidate 後は新規レンダーを受け付けない
    private var isInvalidated = false

    /// 画面外のリソース(不可視の NSWindow と WebContent プロセス)を
    /// 明示的に解放する。使い終えたら呼ぶこと(以後の renderPage は
    /// loadFailed で失敗する)。
    ///
    /// Explicitly tears down the offscreen resources (the invisible NSWindow and
    /// the WebContent process). Call it once you are done (any later renderPage
    /// then fails with loadFailed).
    public func invalidate() {
        isInvalidated = true
        idleReleaseTimer?.cancel()
        queue.cancelAll()
        // cooViewer-oxr.53: delegate を外す前に現在の待機を解決し、
        // 30 秒タイムアウトを待たず FIFO を終了させる。
        host.release()
    }

    /// spine 項目を描画して結果を返す。maxPixelSize は長辺のピクセル数の
    /// 上限(nil なら元の寸法の2倍)。共有する1つの WKWebView を使うため、
    /// 呼び出しは FIFO で完全に直列化する。描画本体は連結した Task の
    /// **内側**で実行する(外へ出すと直列化が崩れ、並行呼び出しが互いの
    /// ナビゲーションを上書きして NavigationWaiter が永久待ちになる)。
    ///
    /// Renders and returns a spine item. maxPixelSize caps the long edge (nil = 2x
    /// native size). Because a single shared WKWebView is used, calls are fully
    /// serialized FIFO: the render body runs **inside** the chained Task (moving
    /// it outside breaks serialization, so concurrent calls clobber each other's
    /// navigations and NavigationWaiter waits forever).
    public func renderPage(atSpineIndex index: Int,
                           maxPixelSize: Int? = nil) async throws -> CGImage {
        try await enqueueRender(
            atSpineIndex: index, maxPixelSize: maxPixelSize,
            deviceViewportSize: nil)
    }

    /// ビューポートに `device-width` または `device-height` を使うページを、
    /// `deviceViewportSize` を端末のビューポート寸法として描画する。
    /// 通常の数値指定のビューポートでは、出版物が宣言した寸法を基準にする。
    ///
    /// Renders a page whose viewport may use `device-width` or
    /// `device-height`, using `deviceViewportSize` as that device viewport.
    /// For ordinary numeric viewports the publication's declared dimensions
    /// remain authoritative.
    public func renderPage(
        atSpineIndex index: Int,
        deviceViewportSize: CGSize,
        maxPixelSize: Int? = nil
    ) async throws -> CGImage {
        try await enqueueRender(
            atSpineIndex: index, maxPixelSize: maxPixelSize,
            deviceViewportSize: deviceViewportSize)
    }

    private func enqueueRender(
        atSpineIndex index: Int, maxPixelSize: Int?,
        deviceViewportSize: CGSize?
    ) async throws -> CGImage {
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        // FIFO 待ちも要求中として数え、最後の描画が終わるまでアイドル解放しない
        // (EPUBScreenThumbnailRenderer と同じ数え方)。
        pendingRenderCount += 1
        idleReleaseTimer?.cancel()
        defer {
            pendingRenderCount -= 1
            scheduleIdleReleaseIfNeeded()
        }
        // 優先度は明示的に userInitiated へ(低優先度の呼び出し元 — 例:
        // .utility のサムネイル先読み — の QoS を継ぐと、WebKit への JS 実行が
        // 応答しないことがある。EPUBScreenThumbnailRenderer で実測した逆転)
        return try await queue.enqueue(priority: .userInitiated) {
            try await self.performRender(atSpineIndex: index,
                                         maxPixelSize: maxPixelSize,
                                         deviceViewportSize: deviceViewportSize)
        }
    }

    private func scheduleIdleReleaseIfNeeded() {
        guard let idleReleaseTimer, !isInvalidated, pendingRenderCount == 0,
              queue.isIdle, hasLiveWebView else { return }
        idleReleaseTimer.restart { [weak self] in
            guard let self, !isInvalidated, pendingRenderCount == 0,
                  queue.isIdle else { return }
            // 恒久的な invalidate にはせず、解放経路だけを通す。次の renderPage は
            // prepareWebView から初回と同じ経路で作り直す。scheme handler は
            // 使い続けるので、Range 応答のキャッシュ(最大 32 MB)もここで手放す。
            queue.clearChain()
            host.release()
            schemeHandler.clearRangeResourceCache()
        }
    }

    private func performRender(atSpineIndex index: Int,
                               maxPixelSize: Int?,
                               deviceViewportSize: CGSize?) async throws -> CGImage {
        // FIFO 待ちの間に invalidate された場合、ここでオフスクリーンを
        // 作り直さない(畳んだはずのウインドウ/プロセスを復活させない)
        try Task.checkCancellation()
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        lastRenderTrace = RenderTrace()
        guard publication.readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        let info = try publication.fixedLayoutInfo(forSpineIndex: index)
        // cooViewer-oxr.50: device-* viewport は固定の 3:4 fallback ではなく、
        // 呼び出し元が要求した描画先の縦横比を ICB として使う。
        let rawViewport = info.viewportIsDeviceSized
            ? (deviceViewportSize ?? CGSize(width: 1200, height: 1600))
            : (info.viewportSize ?? CGSize(width: 1200, height: 1600))
        // 悪意ある FXL は viewport(または SVG viewBox)に巨大値を宣言でき、
        // zoom 下限(0.05)ではフレームを十分に縮められず、巨大なオフスクリーン
        // スナップショット確保でプロセスが落ちる。実在の FXL ページ寸法を
        // 十分に覆う上限へ寸法自体をクランプする(NaN/0/負値も弾く)
        let maxDimension: CGFloat = 5000
        func sane(_ v: CGFloat, fallback: CGFloat) -> CGFloat {
            v.isFinite && v >= 1 ? min(v, maxDimension) : fallback
        }
        let viewport = CGSize(width: sane(rawViewport.width, fallback: 1200),
                              height: sane(rawViewport.height, fallback: 1600))

        // 目標ピクセルに合わせて pageZoom で拡縮(backing scale 込み)。
        // takeSnapshot のピクセル寸法は WebKit が載せ先ウインドウの backing scale で
        // 決めるため、NSScreen.main ではなく実際に描画する画面外ウインドウの値を使う
        // (Retina と非 Retina の混在や 1x ダミー表示では main と食い違い、出力が
        // 2 倍または 1/2 になる)。ウインドウは prepare で初めて作られるので、寸法
        // 決定の前に用意し、確定後に setContentSize で 1 回だけそろえる。
        let webView = try prepareWebView(initialSize: viewport)
        let backingScale = host.window?.backingScaleFactor ?? 2
        let zoom = Self.snapshotZoom(viewport: viewport, backingScale: backingScale,
                                     maxPixelSize: maxPixelSize)
        let frameSize = NSSize(width: viewport.width * zoom,
                               height: viewport.height * zoom)
        host.setContentSize(frameSize)
        webView.pageZoom = zoom
        lastRenderTrace.prepared = .now

        let entry = publication.readingOrder[index]
        guard let url = schemeHandler.url(
            forContainerPath: entry.resolvedContainerPath) else {
            throw EPUBError.resourceNotFound(entry.resolvedContainerPath)
        }
        try await loadAndWait(webView: webView, url: url)
        try Task.checkCancellation()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: frameSize)
        configuration.afterScreenUpdates = true
        let image = try await EPUBOffscreenWaiting.takeSnapshot(
            webView: webView, configuration: configuration)
        lastRenderTrace.snapshotEnd = .now
        try Task.checkCancellation()
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        return image
    }

    /// 初回だけ `initialSize` で構築する。描画寸法は backing scale の確定後に
    /// 巨大要求も bitmap 最大 8192² RGBA (256 MiB) に収める。
    /// viewport 上限だけでは zoom 4 × Retina 2 で長辺 40000 画素まで増えてしまう。
    static func snapshotZoom(viewport: CGSize, backingScale: CGFloat, maxPixelSize: Int?) -> CGFloat {
        let longSide = max(viewport.width, viewport.height)
        let target = min(8192, maxPixelSize.map { max(1, CGFloat($0)) } ?? longSide * 2)
        return max(0.05, min(4, target / (longSide * backingScale)))
    }

    /// 呼び出し元が setContentSize で 1 回だけ設定する(ここで寸法を変えると
    /// 稼働中の WebContent へ余分なジオメトリ更新を送ることになる)。
    private func prepareWebView(initialSize: NSSize) throws -> WKWebView {
        // scheme handler は init で作った 1 つを使い続ける(allowsScriptedContent
        // は不変なので、host が設定の違いで WKWebView を作り直すことはない。
        // アイドル解放の後は新しい WKWebView に同じ handler を登録する)。
        host.prepare(size: initialSize, allowsScriptedContent: allowsScriptedContent,
                     makeSchemeHandler: { schemeHandler })
        guard let webView = host.webView else { throw RasterizeError.loadFailed }
        return webView
    }

    private func loadAndWait(webView: WKWebView, url: URL) async throws {
        try await host.load(url: url, timeout: .seconds(30))
        lastRenderTrace.didFinish = .now
        // didFinish 直後はフォント・画像のデコードが残っていることがある。
        // cooViewer-oxr.2: 一度も表示しないウインドウでは rAF が発火しないため
        // 待ってはいけない。フォントと画像デコードを有界に待ち、描画の確定は
        // takeSnapshot(afterScreenUpdates: true)に任せる
        let readinessReplied = await waitForPostLoadReadiness(webView: webView)
        lastRenderTrace.readinessEnd = .now
        lastRenderTrace.readinessTimedOut = !readinessReplied
        try Task.checkCancellation()
    }

    @discardableResult
    func waitForPostLoadReadiness(webView: WKWebView,
                                  timeout: Duration = .seconds(5)) async -> Bool {
        // 呼び出し元の描画ジョブは userInitiated。キャンセル非対応の
        // async 版で WebView を保持せず、期限後は応答の有無によらず解放する。
        let result: Bool? = await EPUBOffscreenWaiting.waitForResult(
            timeout: timeout
        ) { completion in
            webView.callAsyncJavaScript(
                ReaderScripts.awaitDecodedImagesScript(awaitFonts: true),
                arguments: [:], in: nil, in: .defaultClient) { _ in
                    // 読み込み済みの内容は従来どおり最善努力で描画する。
                    completion(true)
                }
        }
        // Washi-cfm: JS の結果ではなく、期限内に完了通知が届いたかを診断へ渡す。
        return result != nil
    }
}
