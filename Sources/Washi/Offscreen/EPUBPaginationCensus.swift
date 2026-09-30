import AppKit
import WebKit

/// 全 spine 項目のページ数を、本番表示と同一メトリクス(コンテンツ寸法・
/// フォント倍率・見開き・ギャップ)で実測する。リフローのページ数は
/// フォント設定・ウインドウ寸法で変わるため、「本全体で何ページ中の
/// 何ページ目か」を出すにはこの census が必要になる。
///
/// WKWebView はウインドウ外では描画が止まるため、ラスタライザと同じく
/// 画面外の不可視ウインドウに載せた専用 WKWebView で 1 項目ずつ順に
/// 読み込み、本番と同じ __washi.setup() を同じオプションで呼んで
/// pageCount を読み取る(計測式まで完全に一致させるため、推定式の
/// 二重実装はしない)。固定レイアウト項目は本番と同じく 1 ページ扱いで
/// 読み込みを省く。
///
/// 所有者(EPUBReaderView)は本が替わったらインスタンスごと作り直すこと
/// (scheme handler が本に紐づくため)。
@MainActor
final class EPUBPaginationCensus {
    private let host = EPUBOffscreenWebViewHost()
    private let idleReleaseTimer: EPUBOffscreenIdleReleaseTimer
    private let javaScriptTimeoutScheduler: EPUBOffscreenIdleReleaseTimer.Scheduler
    private var pendingMeasurementCount = 0

    /// cooViewer-oxr.68: テストと所有者の診断用。アイドル解放後は false
    /// になり、次の measure が prepareIfNeeded を通ると再び true になる。
    var hasLiveWebView: Bool { host.hasLiveWebView }

    init(
        idleTimerScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler,
        javaScriptTimeoutScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler
    ) {
        idleReleaseTimer = EPUBOffscreenIdleReleaseTimer(
            scheduler: idleTimerScheduler)
        self.javaScriptTimeoutScheduler = javaScriptTimeoutScheduler
    }

    /// 各 spine 項目のページ数を実測する。cooViewer-oxr.22: 欠損などの
    /// 決定的な項目失敗は 1 ページとして続行し、タイムアウト・WebContent
    /// 終了・キャンセルのような一過性失敗では全体を nil にする。
    /// オフスクリーンリソース(不可視 NSWindow + WebContent プロセス)を
    /// 明示的に畳む。ホストが計測を使い終えたとき(ビューのウインドウ離脱・
    /// アトラスの破棄)に呼ぶ。以後 measure が呼ばれれば作り直される
    func invalidate() {
        idleReleaseTimer.cancel()
        releaseOffscreenResources()
    }

    private func releaseOffscreenResources() {
        // cooViewer-oxr.53: delegate を外す前に待機を解決し、15 秒の
        // タイムアウトまで古い census を残さない。
        host.release()
    }

    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize) async -> [Int]? {
        // cooViewer-oxr.68: actor の再入可能区間へ入る前に busy とし、古い
        // タイマを止める。並行 measure も最後の 1 件が抜けるまで
        // 解放しない。
        pendingMeasurementCount += 1
        idleReleaseTimer.cancel()
        defer {
            pendingMeasurementCount -= 1
            scheduleIdleReleaseIfNeeded()
        }
        let allowsScriptedContent = EPUBScreenMetrics.allowsScriptedContent(
            in: optionsJSON)
        var counts: [Int] = []
        counts.reserveCapacity(publication.readingOrder.count)
        for (index, entry) in publication.readingOrder.enumerated() {
            if Task.isCancelled { return nil }
            if publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated,
               !EPUBScreenMetrics.isScrolled(publication.renderingFlow(at: index)) {
                counts.append(1)  // FXL は本番(setup の fxl 分岐)と同じ 1 ページ
                continue
            }
            // ライブ側の contentFrame と同じ項目単位の判断にそろえる
            // (版面が違うと page 数がずれる)。画像だけの項目かの判定は章の展開と
            // 解析を伴うので、メインスレッドの外で行う(結果は publication が保持し、
            // 後の章移動でも使われる)
            let fillsViewport = await Task.detached(priority: Task.currentPriority) {
                EPUBScreenMetrics.fillsViewport(publication, spineIndex: index)
            }.value
            if Task.isCancelled { return nil }
            // cooViewer-oxr.51: 同じ基底メトリクスから itemref ごとの
            // rendition:spread と実効余白を導出し、この項目だけへ渡す。
            let plan = EPUBScreenMetrics.setupPlan(
                optionsJSON: optionsJSON,
                applying: publication.package.effectiveSpread(for: entry.itemRef),
                flow: publication.renderingFlow(at: index),
                fullViewport: fillsViewport)
            let itemSize = plan.contentSize.width >= 1 && plan.contentSize.height >= 1
                ? plan.contentSize : contentSize
            // cooViewer-oxr.22: 欠損項目は本番表示と同じ 1 ページとして扱い、
            // 残りの spine 項目の実測を継続する。
            guard publication.resourceExists(at: entry.resolvedContainerPath) else {
                counts.append(1)
                continue
            }
            prepareIfNeeded(publication: publication, contentSize: itemSize,
                            allowsScriptedContent: allowsScriptedContent)
            guard let webView = host.webView, let schemeHandler = host.schemeHandler,
                  let url = publication.renderingFlow(at: index) == .scrolledContinuous
                    ? schemeHandler.scrollDocumentURL : schemeHandler.url(forReadingOrderItem: entry)
            else {
                counts.append(1)
                continue
            }
            let setupJSON = EPUBScrollDocument.options(
                plan.optionsJSON, publication: publication, index: index,
                handler: schemeHandler, onlyItem: true)
            // 本番の runSetup と同タイミング(didFinish 直後)で測ることで、
            // フォント・画像の遅延読み込みによる誤差の出方まで揃える
            let result: Result<EPUBOffscreenWebViewHost.SetupResult, any Error>?
            do {
                result = try await host.loadAndSetup(
                    url: url, optionsJSON: setupJSON, timeout: .seconds(15),
                    timeoutScheduler: javaScriptTimeoutScheduler)
            } catch {
                // キャンセル時の stopLoading は host.load が済ませている。
                if error is CancellationError || Task.isCancelled {
                    return nil
                }
                if Self.mustAbortMeasurement(for: error) {
                    webView.stopLoading()
                    return nil
                }
                // cooViewer-oxr.22: 非キャンセル・非タイムアウトの決定的な
                // ナビゲーション失敗だけを 1 ページへ縮退する。
                counts.append(1)
                continue
            }
            if Task.isCancelled { return nil }
            guard let result else {
                // 一時的な無応答を 1 ページとして確定・保存しない。
                // 応答しない WebKit も手放し、次回は新しいビューで再計測する。
                releaseOffscreenResources()
                return nil
            }
            guard let count = (try? result.get())?.pageCount else { return nil }
            counts.append(max(1, count))
        }
        return counts
    }

    private func scheduleIdleReleaseIfNeeded() {
        guard pendingMeasurementCount == 0, hasLiveWebView else { return }
        idleReleaseTimer.restart { [weak self] in
            guard let self, pendingMeasurementCount == 0 else { return }
            // cooViewer-oxr.68: invalidate と同じ解放経路を使うが、census 自体は
            // 有効なままなので次の measure が WebKit を遅延再構築できる。
            releaseOffscreenResources()
        }
    }

    static func mustAbortMeasurement(for error: any Error) -> Bool {
        if let waitError = error as? NavigationWaiter.WaitError {
            switch waitError {
            case .timeout, .contentProcessTerminated:
                return true
            }
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled || urlError.code == .timedOut {
                return true
            }
        }
        let nsError = error as NSError
        // cooViewer-oxr.22/53: policy change による load 中断(旧
        // WebKitErrorDomain の 102)と WebContent 終了は決定的な項目破損ではない。
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return true
        }
        if nsError.domain == WKError.errorDomain,
           nsError.code == WKError.Code.webContentProcessTerminated.rawValue {
            return true
        }
        return false
    }

    private func prepareIfNeeded(publication: EPUBPublication,
                                 contentSize: NSSize,
                                 allowsScriptedContent: Bool) {
        // cooViewer-oxr.75: 著者スクリプト許可が変われば host が WKWebView と
        // scheme handler を作り直す(scheme handler は本に紐づくので毎回作る)。
        host.prepare(
            size: contentSize, allowsScriptedContent: allowsScriptedContent,
            makeSchemeHandler: {
                EPUBSchemeHandler(publication: publication,
                                  allowsScripts: allowsScriptedContent)
            },
            installUserScripts: { controller, handler in
                EPUBScrollDocument.install(in: controller, handler: handler)
            })
        // 本番のリフロー時 contentFrame と同寸に保つ(innerWidth/Height 一致が
        // ページ割り一致の前提)
        host.setContentSize(contentSize)
    }
}
