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
    /// Washi-z74.13: invalidate のたびに進む世代。実測は開始時の世代を控え、
    /// await から戻るたびに照合する。NavigationWaiter の再開と MainActor での
    /// 再開の間に invalidate が走っても、取得済みの WebView で続行したり
    /// 次の項目でウインドウを作り直したりしない(EPUBPageRasterizer の
    /// isInvalidated と同じ役目。census は invalidate 後も次の measure で
    /// 作り直せるので、恒久フラグではなく世代で表す)。
    private var invalidationGeneration: UInt = 0

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

    /// オフスクリーンリソース(不可視 NSWindow + WebContent プロセス)を
    /// 明示的に畳む。ホストが計測を使い終えたとき(ビューのウインドウ離脱・
    /// アトラスの破棄)に呼ぶ。以後 measure が呼ばれれば作り直される
    func invalidate() {
        invalidationGeneration &+= 1
        idleReleaseTimer.cancel()
        releaseOffscreenResources()
    }

    private func releaseOffscreenResources() {
        // cooViewer-oxr.53: delegate を外す前に待機を解決し、15 秒の
        // タイムアウトまで古い census を残さない。
        host.release()
    }

    /// 実測の結果。完走すれば `counts` は全 spine 項目ぶん、一過性の中断なら
    /// spine 先頭から連続して測り終えた項目ぶんだけ(同じ本・同じ optionsJSON
    /// での次回の `resuming:` に渡せば続きから測れる)。
    struct Outcome: Equatable {
        var counts: [Int]
        var isComplete: Bool
    }

    /// テスト用: オフスクリーン WebView で読み込んだ項目の累計(FXL・欠損
    /// 項目は読み込まないので数えない)。再開が残りの項目だけを読むことの観測点
    private(set) var loadedItemCount = 0

    /// 各 spine 項目のページ数を実測する。cooViewer-oxr.22: 欠損などの
    /// 決定的な項目失敗は 1 ページとして続行し、タイムアウト・WebContent
    /// 終了・キャンセルのような一過性失敗では全体を nil にする。
    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize) async -> [Int]? {
        let outcome = await measure(publication: publication, optionsJSON: optionsJSON,
                                    contentSize: contentSize, resuming: [])
        return outcome.isComplete ? outcome.counts : nil
    }

    /// 途中から再開できる実測。`prefix` は同じ本・同じ optionsJSON での以前の
    /// 中断時に測り終えていた先頭部分(``Outcome/counts``)。項目ごとのページ数は
    /// (本, optionsJSON, spine 位置)だけで決まるので、続きから測っても
    /// 一気に測ったときと同じ配列になる。別のキーや別の本の先頭部分を渡さないこと
    /// (呼び出し側が責任を持つ)。
    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize, resuming prefix: [Int]) async -> Outcome {
        // cooViewer-oxr.68: actor の再入可能区間へ入る前に busy とし、古い
        // タイマを止める。並行 measure も最後の 1 件が抜けるまで
        // 解放しない。
        pendingMeasurementCount += 1
        idleReleaseTimer.cancel()
        defer {
            pendingMeasurementCount -= 1
            scheduleIdleReleaseIfNeeded()
        }
        // Washi-z74.13: 呼び出し元のキャンセルと同じく、この実測の開始後の
        // invalidate も一過性の中断として扱い、未完で抜ける(測り終えた先頭部分
        // だけを返す)。
        let generation = invalidationGeneration
        func isAborted() -> Bool {
            Task.isCancelled || generation != invalidationGeneration
        }
        let allowsScriptedContent = EPUBScreenMetrics.allowsScriptedContent(
            in: optionsJSON)
        let readingOrder = publication.readingOrder
        var counts = Array(prefix.prefix(readingOrder.count))
        counts.reserveCapacity(readingOrder.count)
        func interrupted() -> Outcome { Outcome(counts: counts, isComplete: false) }
        for index in counts.count..<readingOrder.count {
            let entry = readingOrder[index]
            if isAborted() { return interrupted() }
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
            if isAborted() { return interrupted() }
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
            let setupJSON = Self.setupJSON(omittingPrintPageMarkers: EPUBScrollDocument.options(
                plan.optionsJSON, publication: publication, index: index,
                handler: schemeHandler, onlyItem: true))
            // 本番の runSetup と同タイミング(didFinish 直後)で測ることで、
            // フォント・画像の遅延読み込みによる誤差の出方まで揃える
            let result: Result<EPUBOffscreenWebViewHost.SetupResult, any Error>?
            loadedItemCount += 1
            do {
                result = try await host.loadAndSetup(
                    url: url, optionsJSON: setupJSON, timeout: .seconds(15),
                    timeoutScheduler: javaScriptTimeoutScheduler)
            } catch {
                // キャンセル時の stopLoading は host.load が済ませている。
                if error is CancellationError || isAborted() {
                    return interrupted()
                }
                if Self.mustAbortMeasurement(for: error) {
                    webView.stopLoading()
                    return interrupted()
                }
                // cooViewer-oxr.22: 非キャンセル・非タイムアウトの決定的な
                // ナビゲーション失敗だけを 1 ページへ縮退する。
                counts.append(1)
                continue
            }
            if isAborted() { return interrupted() }
            guard let result else {
                // 一時的な無応答を 1 ページとして確定・保存しない。
                // 応答しない WebKit も手放し、次回は新しいビューで再計測する
                // (測り終えた先頭部分は有効なので、再計測は続きから)。
                releaseOffscreenResources()
                return interrupted()
            }
            guard let count = (try? result.get())?.pageCount else { return interrupted() }
            counts.append(max(1, count))
        }
        return Outcome(counts: counts, isComplete: true)
    }

    /// 項目ごとの setup JSON にだけ skipPrintPageMarkers を足す(鍵 = cacheKey には触れない)
    static func setupJSON(omittingPrintPageMarkers json: String) -> String {
        guard let data = json.data(using: .utf8),
              var options = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        options[.skipPrintPageMarkers] = true
        guard let encoded = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        else { return json }
        return String(data: encoded, encoding: .utf8) ?? json
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
        // cooViewer-oxr.22/53: policy change による load 中断(旧
        // WebKitErrorDomain の 102)と WebContent 終了は決定的な項目破損ではない。
        if NavigationWaiter.isCancellation(error) {
            return true
        }
        let nsError = error as NSError
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
