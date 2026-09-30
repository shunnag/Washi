import AppKit
import WebKit

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

    init(
        publication: EPUBPublication,
        idleTimerScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler
    ) {
        self.publication = publication
        idleReleaseTimer = EPUBOffscreenIdleReleaseTimer(
            scheduler: idleTimerScheduler)
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
        // FXL は幅を 2 倍して Int に変換する。非有限値や変換不能な値を
        // WebKit の構築前に拒否し、例外で捕捉できない変換トラップを防ぐ。
        guard !isInvalidated, snapshotWidth.isFinite, snapshotWidth > 0,
              snapshotWidth < CGFloat(Int.max) / 2 else { return nil }
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
        return await queue.enqueue(priority: .userInitiated) {
            await self.render(
                spineIndex: spineIndex, pageInItem: pageInItem,
                optionsJSON: optionsJSON, contentSize: contentSize,
                snapshotWidth: snapshotWidth)
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
                        snapshotWidth: CGFloat) async -> CGImage? {
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
                atSpineIndex: spineIndex, maxPixelSize: Int(snapshotWidth * 2))
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

    /// ほぼ無地(1 色)のスナップショットか。16x16 へ縮小して各チャネルの
    /// 振れ幅を見る(初回描画の合成抜け検知用)
    private static func looksBlank(_ image: CGImage) -> Bool {
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
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
