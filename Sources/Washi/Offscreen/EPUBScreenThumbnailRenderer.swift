import AppKit
import WebKit

/// 旧 API のポイント幅と、表示倍率に依存しないピクセル長辺を区別する。
enum ScreenThumbnailSize: Equatable {
    case widthInPoints(CGFloat)
    case maxPixelSize(Int)

    @MainActor var isValid: Bool {
        switch self {
        case .widthInPoints(let width):
            return EPUBReaderView.snapshotPixelDimensions(
                size: CGSize(width: width, height: width), scale: 1) != nil
        case .maxPixelSize(let size):
            return (1...8192).contains(size)
        }
    }

    func snapshotWidth(contentSize: CGSize, backingScale: CGFloat) -> CGFloat {
        switch self {
        case .widthInPoints(let width): return width
        case .maxPixelSize(let size):
            return CGFloat(size) * contentSize.width
                / max(contentSize.width, contentSize.height) / backingScale
        }
    }

    /// 旧 FXL 経路は幅指定を長辺として扱っていた。単位だけ実際の倍率で換算する。
    func rasterizerMaxPixelSize(backingScale: CGFloat) -> Int? {
        switch self {
        case .widthInPoints(let width):
            return Int(exactly: (width * backingScale).rounded(.towardZero))
        case .maxPixelSize(let size): return size
        }
    }
}

/// リフロー EPUB の「画面」(単ページ/見開きの 1 面)のサムネイルを、
/// 本番と同一メトリクスのページ割りで画面外に描くレンダラ。
/// census と同じオフスクリーンウインドウ方式で、共有 WKWebView を
/// FIFO 直列化して使う(EPUBPageRasterizer と同じチェーン方式 —
/// 並行呼び出しは相互のナビゲーションを潰すため直列が必須)。
/// 同じ spine 項目への連続要求は読み込みを再利用する(サムネイル一覧の
/// 要求順はほぼ逐次なので効く)。固定レイアウト項目は EPUBPageRasterizer
/// に委譲する。
@MainActor
final class EPUBScreenThumbnailRenderer {
    private let publication: EPUBPublication
    private let host = EPUBOffscreenWebViewHost()
    private var fxlRasterizer: EPUBPageRasterizer?
    private var fxlAllowsScriptedContent: Bool?
    private let idleReleaseTimer: EPUBOffscreenIdleReleaseTimer
    private let energyPacer: EPUBOffscreenEnergyPacer
    private var pendingRenderRequestCount = 0
    private var loadedSpineIndex: Int?
    private var loadedOptionsJSON: String?
    /// FIFO 直列化(EPUBPageRasterizer と同じチェーン方式)
    private let queue = EPUBOffscreenJobQueue()
    /// invalidate 後は新規レンダーを受け付けない(再利用はしない前提)
    private var isInvalidated = false

    /// cooViewer-oxr.68: リフロー用または FXL 用の WebKit が生存中かを示す。
    var hasLiveWebView: Bool {
        host.hasLiveWebView || fxlRasterizer?.hasLiveWebView == true
    }

    /// `energyPacer` は所有者が census と共有する(方針の実体)。FXL の委譲先
    /// ラスタライザは同じ FIFO のジョブとして走るので、ここでの休止で足りる。
    init(
        publication: EPUBPublication,
        idleTimerScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler,
        energyPacer: EPUBOffscreenEnergyPacer = EPUBOffscreenEnergyPacer()
    ) {
        self.publication = publication
        idleReleaseTimer = EPUBOffscreenIdleReleaseTimer(
            scheduler: idleTimerScheduler)
        self.energyPacer = energyPacer
    }

    /// オフスクリーンリソースを明示的に畳み、以後の要求を無効化する。
    /// FIFO 待ちのジョブは順に nil を返して抜ける
    func invalidate() {
        isInvalidated = true
        idleReleaseTimer.cancel()
        queue.cancelAll()
        releaseOffscreenResources()
    }

    private func releaseOffscreenResources() {
        // cooViewer-oxr.62: delegate を外す前に現在の待機を解決し、
        // 15 秒タイムアウトまでサムネイル要求を残さない。
        host.release()
        forgetLoadedDocument()
        fxlRasterizer?.invalidate()
        fxlRasterizer = nil
        fxlAllowsScriptedContent = nil
    }

    /// 読み込み済みの文書を忘れ、次の要求で読み込み直させる
    private func forgetLoadedDocument() {
        loadedSpineIndex = nil
        loadedOptionsJSON = nil
    }

    /// 指定画面のサムネイル。失敗時は nil(一覧側は空セルのまま先へ進める)
    func thumbnail(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                   contentSize: NSSize, snapshotWidth: CGFloat) async -> CGImage? {
        await thumbnail(spineIndex: spineIndex, pageInItem: pageInItem,
                        optionsJSON: optionsJSON, contentSize: contentSize,
                        size: .widthInPoints(snapshotWidth))
    }

    func thumbnail(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                   contentSize: NSSize, size: ScreenThumbnailSize) async -> CGImage? {
        guard !isInvalidated, size.isValid,
              EPUBReaderView.snapshotPixelDimensions(size: contentSize, scale: 1) != nil else { return nil }
        // cooViewer-oxr.68: FIFO 待ちも要求中として数え、最後の呼び出しが
        // 完了するまで不可視 WebKit を解放しない。
        pendingRenderRequestCount += 1
        idleReleaseTimer.cancel()
        defer {
            pendingRenderRequestCount -= 1
            scheduleIdleReleaseIfNeeded()
        }
        // 優先度は明示的に userInitiated へ引き上げる。呼び出し元はサムネイル
        // 先読み(.utility の detached タスク)で、その優先度のまま WebKit へ
        // JS 実行を発行すると応答が返らない(QoS 逆転で永久待ち。実測)。
        return await queue.enqueue(priority: .userInitiated) { () async -> CGImage? in
            // ジョブの間の休止(followSystem で省エネが求められているときだけ)。
            // FIFO の中で待つので先行ジョブとの間が空き、優先度はこのジョブのまま。
            do {
                try await self.energyPacer.pauseBeforeJobIfNeeded()
            } catch {
                return nil
            }
            guard !self.isInvalidated, !Task.isCancelled else { return nil }
            let image = await self.render(
                spineIndex: spineIndex, pageInItem: pageInItem,
                optionsJSON: optionsJSON, contentSize: contentSize,
                size: size)
            guard let image, case .maxPixelSize(let pixels) = size else { return image }
            return Self.resized(image, maxPixelSize: pixels)
        }
    }

    private func scheduleIdleReleaseIfNeeded() {
        guard !isInvalidated, pendingRenderRequestCount == 0,
              queue.isIdle, hasLiveWebView else { return }
        idleReleaseTimer.restart { [weak self] in
            guard let self, !isInvalidated, pendingRenderRequestCount == 0,
                  queue.isIdle else { return }
            // cooViewer-oxr.68: 永続 invalidate にはせず、同じ解放経路だけを
            // 通して次の thumbnail で prepareIfNeeded から再構築する。
            queue.clearChain()
            releaseOffscreenResources()
        }
    }

    private func render(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                        contentSize: NSSize,
                        size: ScreenThumbnailSize) async -> CGImage? {
        guard !isInvalidated,
              publication.readingOrder.indices.contains(spineIndex) else { return nil }
        let entry = publication.readingOrder[spineIndex]
        let flow = publication.renderingFlow(at: spineIndex)
        // ライブ側の contentFrame と同じ項目単位の判断にそろえる。そろえないと
        // サムネイルだけ余白ぶん内側の箱になり、画像の収まりが実表示と食い違う。
        // 画像だけの項目かの判定は章の展開と解析を伴うので、メインスレッドの外で行う
        let book = publication
        let fillsViewport = await Task.detached(priority: Task.currentPriority) {
            EPUBScreenMetrics.fillsViewport(book, spineIndex: spineIndex)
        }.value
        guard !isInvalidated, !Task.isCancelled else { return nil }
        let plan = EPUBScreenMetrics.setupPlan(
            optionsJSON: optionsJSON,
            applying: publication.package.effectiveSpread(for: entry.itemRef), flow: flow,
            fullViewport: fillsViewport)
        let optionsJSON = plan.optionsJSON
        let contentSize = plan.contentSize.width >= 1 && plan.contentSize.height >= 1
            ? plan.contentSize : contentSize
        let allowsScriptedContent = EPUBScreenMetrics.allowsScriptedContent(
            in: optionsJSON)
        if publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated,
           !EPUBScreenMetrics.isScrolled(flow) {
            // FXL は viewport・spread 指定を解釈する専用ラスタライザで
            if fxlRasterizer == nil
                || fxlAllowsScriptedContent != allowsScriptedContent {
                fxlRasterizer?.invalidate()
                fxlRasterizer = EPUBPageRasterizer(
                    publication: publication,
                    allowsScriptedContent: allowsScriptedContent)
                fxlAllowsScriptedContent = allowsScriptedContent
            }
            guard let fxlRasterizer else { return nil }
            return try? await fxlRasterizer.renderPage(
                atSpineIndex: spineIndex, thumbnailSize: size)
        }
        prepareIfNeeded(contentSize: contentSize,
                        allowsScriptedContent: allowsScriptedContent)
        guard let webView = host.webView, let schemeHandler = host.schemeHandler
        else { return nil }
        if loadedSpineIndex != spineIndex || loadedOptionsJSON != optionsJSON {
            guard let url = flow == .scrolledContinuous ? schemeHandler.scrollDocumentURL
                    : schemeHandler.url(forReadingOrderItem: entry)
            else { return nil }
            forgetLoadedDocument()  // 途中失敗時に半端な状態を再利用しない
            host.setContentSize(contentSize)
            let setupJSON = EPUBScrollDocument.options(
                optionsJSON, publication: publication, index: spineIndex, handler: schemeHandler)
            // census と同じく didFinish 直後に測る(ページ数の一致が最優先。
            // 描画の確定は takeSnapshot(afterScreenUpdates: true)が担う)。
            // invalidate は実行中のジョブを cancel するので、読み込み直後の
            // 判定は host 側の Task.isCancelled で足りる。
            let setup: Result<EPUBOffscreenWebViewHost.SetupResult, any Error>?
            do {
                setup = try await host.loadAndSetup(
                    url: url, optionsJSON: setupJSON, timeout: .seconds(15))
            } catch {
                return nil
            }
            let didSetup = setup.map { (try? $0.get()) != nil }
            guard didSetup == true, !Task.isCancelled, !isInvalidated else {
                return nil
            }
            loadedSpineIndex = spineIndex
            loadedOptionsJSON = optionsJSON
        }
        // 指定画面へジャンプ(描画確定は afterScreenUpdates が担う)
        let didShowPage = await EPUBOffscreenWaiting.waitForResult { completion in
            webView.callAsyncJavaScript(
                "__washi.showPage(\(pageInItem)); return true;",
                arguments: [:], in: nil, in: WashiContentWorld.world,
                completionHandler: { _ in completion(true) })
        }
        guard didShowPage == true, !Task.isCancelled, !isInvalidated else {
            forgetLoadedDocument()
            return nil
        }
        // 画像を含むページ(表紙・挿絵)はデコード完了を待ってから撮る。
        // 新規 webview の初回スナップショットは img が未デコードのまま
        // 白紙に写ることがある(実測)。img.decode() は Promise ベースで
        // rAF/可視性に依存しない。ラスタライザと同じ 1500ms の JS 側上限に
        // Swift 側 5 秒の上限を重ね、デコードも WebKit 自体の無応答も打ち切る。
        let didDecode = await EPUBOffscreenWaiting.waitForResult { completion in
            webView.callAsyncJavaScript(
                ReaderScripts.awaitDecodedImagesScript(awaitFonts: false),
                arguments: [:], in: nil, in: WashiContentWorld.world,
                completionHandler: { result in
                    // JS エラーは従来どおり許容し、期限切れの false は失敗にする。
                    completion((try? result.get()) as? Bool != false)
                })
        }
        guard didDecode == true, !Task.isCancelled, !isInvalidated else {
            forgetLoadedDocument()
            return nil
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        // WebKit の snapshotWidth はポイント。ピクセル指定だけ実ウインドウの
        // 倍率で割り、本文の寸法・ページ割りはそのまま保つ。
        guard let backingScale = host.window?.backingScaleFactor else { return nil }
        let snapshotWidth = max(1, size.snapshotWidth(contentSize: contentSize,
                                                     backingScale: backingScale))
        guard EPUBReaderView.snapshotPixelDimensions(
            size: CGSize(width: snapshotWidth,
                         height: snapshotWidth * contentSize.height / contentSize.width),
            scale: backingScale) != nil else { return nil }
        configuration.snapshotWidth = NSNumber(value: Double(snapshotWidth))
        var cgImage = try? await EPUBOffscreenWaiting.takeSnapshot(
            webView: webView, configuration: configuration)
        guard !Task.isCancelled, !isInvalidated else { return nil }
        // 新規 webview の最初のナビゲーションが画像ページ(表紙等)だと、
        // DOM・デコード完了後でも画像レイヤの合成が間に合わず**無地**の
        // スナップショットになることがある(実測)。無地を検知したら
        // 少し待って撮り直す(本当に無地のページでも 2 回で諦めるだけ)
        var retries = 0
        while let current = cgImage, Self.looksBlank(current), retries < 2 {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return nil
            }
            guard !isInvalidated else { return nil }
            cgImage = try? await EPUBOffscreenWaiting.takeSnapshot(
                webView: webView, configuration: configuration)
            guard !Task.isCancelled, !isInvalidated else { return nil }
            retries += 1
        }
        return cgImage
    }

    /// WebKit の端数丸め・拡縮上限を吸収し、ピクセル指定の長辺を正確にそろえる。
    static func resized(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide != maxPixelSize else { return image }
        let ratio = CGFloat(maxPixelSize) / CGFloat(longSide)
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// ほぼ無地(1 色)のスナップショットか。16x16 へ縮小して各チャネルの
    /// 振れ幅を見る(初回描画の合成抜け検知用)
    static func looksBlank(_ image: CGImage) -> Bool {
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        // data は context が所有する。走査の最後まで ARC に解放させない。
        return withExtendedLifetime(context) {
            let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
            var minValue: [UInt8] = [255, 255, 255]
            var maxValue: [UInt8] = [0, 0, 0]
            for pixel in 0..<(side * side) {
                for channel in 0..<3 {
                    let value = pixels[pixel * 4 + channel]
                    minValue[channel] = min(minValue[channel], value)
                    maxValue[channel] = max(maxValue[channel], value)
                }
            }
            return (0..<3).allSatisfy { maxValue[$0] - minValue[$0] < 8 }
        }
    }

    private func prepareIfNeeded(contentSize: NSSize,
                                 allowsScriptedContent: Bool) {
        // 画面外・非表示・クリック不可(census/ラスタライザと同じ方式)。
        // 寸法は新しい spine 項目を読み込むときにだけそろえる。
        let didRebuildWebView = host.prepare(
            size: contentSize, allowsScriptedContent: allowsScriptedContent,
            makeSchemeHandler: {
                EPUBSchemeHandler(publication: publication,
                                  allowsScripts: allowsScriptedContent)
            },
            installUserScripts: { controller, handler in
                EPUBScrollDocument.install(in: controller, handler: handler)
            })
        if didRebuildWebView {
            // cooViewer-oxr.75: 著者スクリプト許可が変われば、構成が不変の
            // WKWebView と scheme handler を同じ条件で作り直す。
            forgetLoadedDocument()
        }
    }
}
