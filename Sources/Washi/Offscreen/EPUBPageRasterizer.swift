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
    public init(publication: EPUBPublication) {
        self.publication = publication
        self.allowsScriptedContent = false
        self.schemeHandler = EPUBSchemeHandler(
            publication: publication, allowsScripts: false)
    }

    /// 画面外のページで著者スクリプトを実行できるかを指定して、
    /// ラスタライザを作る。
    ///
    /// Creates a rasterizer and chooses whether author scripts may run in the
    /// offscreen page.
    public init(publication: EPUBPublication, allowsScriptedContent: Bool) {
        self.publication = publication
        self.allowsScriptedContent = allowsScriptedContent
        self.schemeHandler = EPUBSchemeHandler(
            publication: publication, allowsScripts: allowsScriptedContent)
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
        // 優先度は明示的に userInitiated へ(低優先度の呼び出し元 — 例:
        // .utility のサムネイル先読み — の QoS を継ぐと、WebKit への JS 実行が
        // 応答しないことがある。EPUBScreenThumbnailRenderer で実測した逆転)
        return try await queue.enqueue(priority: .userInitiated) {
            try await self.performRender(atSpineIndex: index,
                                         maxPixelSize: maxPixelSize,
                                         deviceViewportSize: deviceViewportSize)
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

        // 目標ピクセルに合わせて pageZoom で拡縮(backing scale 込み)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let longSide = max(viewport.width, viewport.height)
        let targetLongSidePixels = maxPixelSize.map { max(1, CGFloat($0)) }
            ?? longSide * 2  // 既定は 2x(Retina 実寸)
        let zoom = max(0.05, min(4, targetLongSidePixels / (longSide * backingScale)))
        let frameSize = NSSize(width: viewport.width * zoom,
                               height: viewport.height * zoom)

        let webView = try prepareWebView(size: frameSize)
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
        let image = try await takeOffscreenSnapshot(
            webView: webView, configuration: configuration)
        lastRenderTrace.snapshotEnd = .now
        try Task.checkCancellation()
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        return image
    }

    private func prepareWebView(size: NSSize) throws -> WKWebView {
        // scheme handler は init で作った 1 つを使い続ける(allowsScriptedContent
        // は不変なので、host が WKWebView を作り直すことはない)。
        host.prepare(size: size, allowsScriptedContent: allowsScriptedContent,
                     makeSchemeHandler: { schemeHandler })
        host.setContentSize(size)
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
        let result: Bool? = await waitForOffscreenResult(timeout: timeout) { completion in
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
