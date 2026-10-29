import AppKit
import WebKit

/// 全 spine 項目のページ数を、本番表示と同一メトリクス(コンテンツ寸法・
/// フォント倍率・見開き・ギャップ)で実測する。リフローのページ数は
/// フォント設定・ウインドウ寸法で変わるため、「本全体で何ページ中の
/// 何ページ目か」を出すにはこの census が必要になる。
///
/// WKWebView はウインドウ外では描画が止まるため、ラスタライザと同じく
/// 画面外の不可視ウインドウに載せた最大 4 つの専用 WKWebView で項目を分担して
/// 読み込み、本番と同じ __washi.setup() を同じオプションで呼んで
/// pageCount を読み取る(計測式まで完全に一致させるため、推定式の
/// 二重実装はしない)。固定レイアウト項目は本番と同じく 1 ページ扱いで
/// 読み込みを省く。
///
/// 所有者(EPUBReaderView)は本が替わったらインスタンスごと作り直すこと
/// (scheme handler が本に紐づくため)。
@MainActor
final class EPUBPaginationCensus {
    private var hosts: [EPUBOffscreenWebViewHost] = []
    private let queue = EPUBOffscreenJobQueue()
    private let maximumWorkers: Int
    private let resourceBudget: @MainActor () -> (physicalMemory: UInt64, isUnderPressure: Bool)
    private let poolExpansionThreshold: Duration
    private let idleReleaseTimer: EPUBOffscreenIdleReleaseTimer
    private let idleTimerScheduler: EPUBOffscreenIdleReleaseTimer.Scheduler
    private var workerIdleTimers: [EPUBOffscreenIdleReleaseTimer] = []
    private let javaScriptTimeoutScheduler: EPUBOffscreenIdleReleaseTimer.Scheduler
    private let energyPacer: EPUBOffscreenEnergyPacer
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
    var hasLiveWebView: Bool { hosts.contains { $0.hasLiveWebView } }
    var liveWebViewCount: Int { hosts.filter { $0.hasLiveWebView }.count }
    private(set) var lastWorkerCount = 0

    /// `energyPacer` は所有者が census とサムネイルレンダラで共有する(方針の実体)。
    init(
        idleTimerScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler,
        javaScriptTimeoutScheduler: @escaping EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler,
        energyPacer: EPUBOffscreenEnergyPacer = EPUBOffscreenEnergyPacer(),
        maximumWorkers: Int = 4,
        resourceBudget: @escaping @MainActor () -> (physicalMemory: UInt64, isUnderPressure: Bool) = {
            (ProcessInfo.processInfo.physicalMemory, CensusMemoryPressure.shared.isUnderPressure)
        },
        poolExpansionThreshold: Duration = CensusPoolExpansion.remainingTimeThreshold
    ) {
        idleReleaseTimer = EPUBOffscreenIdleReleaseTimer(
            scheduler: idleTimerScheduler)
        self.idleTimerScheduler = idleTimerScheduler
        self.javaScriptTimeoutScheduler = javaScriptTimeoutScheduler
        self.energyPacer = energyPacer
        self.maximumWorkers = maximumWorkers
        self.resourceBudget = resourceBudget
        self.poolExpansionThreshold = poolExpansionThreshold
    }

    /// オフスクリーンリソース(不可視 NSWindow + WebContent プロセス)を
    /// 明示的に畳む。ホストが計測を使い終えたとき(ビューのウインドウ離脱・
    /// アトラスの破棄)に呼ぶ。以後 measure が呼ばれれば作り直される
    func invalidate() {
        invalidationGeneration &+= 1
        idleReleaseTimer.cancel()
        queue.cancelAll()
        releaseOffscreenResources()
        hosts.removeAll()
        workerIdleTimers.removeAll()
    }

    private func releaseOffscreenResources() {
        // cooViewer-oxr.53: delegate を外す前に待機を解決し、15 秒の
        // タイムアウトまで古い census を残さない。
        for timer in workerIdleTimers { timer.cancel() }
        for host in hosts { host.release() }
    }

    /// 実測の結果。完走すれば `counts` は全 spine 項目ぶん、一過性の中断なら
    /// spine 先頭から連続して測り終えた項目ぶんだけ(同じ本・同じ optionsJSON
    /// での次回の `resuming:` に渡せば続きから測れる)。
    struct Outcome: Equatable, Sendable {
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
        // タイマを止める。各ワーカーが使い終えたホストだけをアイドル解放する。
        pendingMeasurementCount += 1
        idleReleaseTimer.cancel()
        for timer in workerIdleTimers { timer.cancel() }
        defer {
            pendingMeasurementCount -= 1
            scheduleIdleReleaseIfNeeded()
        }
        let generation = invalidationGeneration
        let prefix = Array(prefix.prefix(publication.readingOrder.count))
        if prefix.count == publication.readingOrder.count {
            return Outcome(counts: prefix, isComplete: true)
        }
        do {
            // 同じ census への並行要求はプール全体で直列化する。別要求が同じ
            // ホストへナビゲーションを重ね、先行要求の待機を壊すことを防ぐ。
            return try await queue.enqueue { [self] in
                await performMeasurement(publication: publication, optionsJSON: optionsJSON,
                                         contentSize: contentSize, prefix: prefix, generation: generation)
            }
        } catch {
            return Outcome(counts: prefix, isComplete: false)
        }
    }

    private func workerLimit(spineCount: Int) -> Int {
        let budget = resourceBudget()
        return CensusConcurrency.workerCount(
            physicalMemory: budget.physicalMemory, isConserving: energyPacer.isConserving,
            isUnderMemoryPressure: budget.isUnderPressure, spineCount: spineCount,
            maximumWorkers: maximumWorkers)
    }

    private func performMeasurement(publication: EPUBPublication, optionsJSON: String,
                                    contentSize: NSSize, prefix: [Int], generation: UInt) async -> Outcome {
        func isAborted() -> Bool {
            Task.isCancelled || generation != invalidationGeneration
        }
        // 旧世代の要求がまだ FIFO から戻る途中でも、新世代のホストには触れない。
        guard !isAborted() else { return .init(counts: prefix, isComplete: false) }
        let existingHosts = hosts
        defer {
            if isAborted() { for host in existingHosts { host.release() } }
        }
        do {
            try await energyPacer.waitUntilStartAllowed(isAborted: { isAborted() })
        } catch {
            return .init(counts: prefix, isComplete: false)
        }
        guard !isAborted() else { return .init(counts: prefix, isComplete: false) }
        // enqueue 待機中にも先行ワーカーが idle 期限を予約しうるので、貸出時に再度止める。
        for timer in workerIdleTimers { timer.cancel() }
        // 毎回、前回の主ホスト 1 つだけで始める。短い本では追加の WebContent を起動しない。
        for host in hosts.dropFirst() { host.release() }
        for timer in workerIdleTimers.dropFirst() { timer.cancel() }
        hosts = Array(hosts.prefix(1))
        workerIdleTimers = Array(workerIdleTimers.prefix(1))
        if hosts.isEmpty {
            hosts.append(EPUBOffscreenWebViewHost())
            workerIdleTimers.append(EPUBOffscreenIdleReleaseTimer(scheduler: idleTimerScheduler))
        }
        lastWorkerCount = 1
        let serialHost = hosts[0]
        let itemCount = publication.readingOrder.count
        let allowsScriptedContent = EPUBScreenMetrics.allowsScriptedContent(in: optionsJSON)
        var counts = prefix
        var expansion = CensusPoolExpansion(threshold: poolExpansionThreshold)
        var count = 1
        for index in prefix.count..<itemCount {
            guard !isAborted() else {
                serialHost.release()
                return .init(counts: counts, isComplete: false)
            }
            let loadedBefore = loadedItemCount
            let start = ContinuousClock.now
            let pages = await measureItem(
                index, publication: publication, optionsJSON: optionsJSON, contentSize: contentSize,
                allowsScriptedContent: allowsScriptedContent, host: serialHost, isAborted: { isAborted() })
            guard !isAborted(), let pages else {
                serialHost.release()
                return .init(counts: counts, isComplete: false)
            }
            counts.append(pages)
            // FXL・欠損項目の短絡は WebKit の項目時間へ混ぜない。
            if loadedItemCount > loadedBefore { expansion.recordItemTime(ContinuousClock.now - start) }
            count = expansion.workerCount(
                remainingItemCount: itemCount - counts.count,
                gatedWorkerCount: workerLimit(spineCount: itemCount))
            if count > 1 { break }
        }
        if counts.count == itemCount { return .init(counts: counts, isComplete: true) }
        lastWorkerCount = count
        while hosts.count < count {
            hosts.append(EPUBOffscreenWebViewHost())
            workerIdleTimers.append(EPUBOffscreenIdleReleaseTimer(scheduler: idleTimerScheduler))
        }
        // invalidate 後の次要求は新しいホストを使う。古い await の後処理が
        // 新要求の WebView を解放しないよう、この計測の参照だけを保持する。
        let runHosts = hosts
        let runTimers = workerIdleTimers
        return await CensusWorkerPool.run(
            itemCount: itemCount, prefix: counts, workerCount: count,
            workerLimit: { self.workerLimit(spineCount: publication.readingOrder.count) },
            isAborted: { isAborted() },
            onInterrupt: {
                for timer in runTimers { timer.cancel() }
                for host in runHosts { host.release() }
            },
            onWorkerFinished: { worker in
                if worker >= self.workerLimit(spineCount: publication.readingOrder.count) {
                    runHosts[worker].release()
                } else if worker > 0, runHosts[worker].hasLiveWebView,
                          generation == self.invalidationGeneration {
                    // 大きい最後の章を別ホストが計測中でも、仕事の尽きた追加ホストは
                    // 自分の最終利用から 20 秒で解放する。次の要求はこの期限を取り消す。
                    runTimers[worker].restart { [weak host = runHosts[worker]] in host?.release() }
                }
            },
            measure: { worker, index in
                await self.measureItem(index, publication: publication, optionsJSON: optionsJSON,
                                       contentSize: contentSize, allowsScriptedContent: allowsScriptedContent,
                                       host: runHosts[worker], isAborted: { isAborted() })
            })
    }

    private func measureItem(_ index: Int, publication: EPUBPublication, optionsJSON: String,
                             contentSize: NSSize, allowsScriptedContent: Bool,
                             host: EPUBOffscreenWebViewHost,
                             isAborted: () -> Bool) async -> Int? {
        guard !isAborted() else { return nil }
        let entry = publication.readingOrder[index]
        if publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated,
           !EPUBScreenMetrics.isScrolled(publication.renderingFlow(at: index)) {
            return 1  // FXL は本番と同じ 1 ページで、WebKit を使わない。
        }
        let fillsViewport = await Task.detached(priority: .userInitiated) {
            EPUBScreenMetrics.fillsViewport(publication, spineIndex: index)
        }.value
        guard !isAborted() else { return nil }
        let plan = EPUBScreenMetrics.setupPlan(
            optionsJSON: optionsJSON,
            applying: publication.package.effectiveSpread(for: entry.itemRef),
            flow: publication.renderingFlow(at: index), fullViewport: fillsViewport)
        let itemSize = plan.contentSize.width >= 1 && plan.contentSize.height >= 1
            ? plan.contentSize : contentSize
        guard publication.resourceExists(at: entry.resolvedContainerPath) else { return 1 }
        do {
            try await energyPacer.pauseBeforeJobIfNeeded()
        } catch {
            return nil
        }
        guard !isAborted() else { return nil }
        prepareIfNeeded(host: host, publication: publication, contentSize: itemSize,
                        allowsScriptedContent: allowsScriptedContent)
        guard let webView = host.webView, let schemeHandler = host.schemeHandler,
              let url = publication.renderingFlow(at: index) == .scrolledContinuous
                ? schemeHandler.scrollDocumentURL : schemeHandler.url(forReadingOrderItem: entry)
        else { return 1 }
        let setupJSON = Self.setupJSON(omittingPrintPageMarkers: EPUBScrollDocument.options(
            plan.optionsJSON, publication: publication, index: index,
            handler: schemeHandler, onlyItem: true))
        loadedItemCount += 1
        let result: Result<EPUBOffscreenWebViewHost.SetupResult, any Error>?
        do {
            result = try await host.loadAndSetup(
                url: url, optionsJSON: setupJSON, timeout: .seconds(15),
                timeoutScheduler: javaScriptTimeoutScheduler)
        } catch {
            guard !isAborted(), !(error is CancellationError) else { return nil }
            if Self.mustAbortMeasurement(for: error) {
                webView.stopLoading()
                return nil
            }
            // 決定的なナビゲーション失敗だけを従来どおり 1 ページへ縮退する。
            return 1
        }
        guard !isAborted(), let result, let pageCount = (try? result.get())?.pageCount
        else { return nil }
        return max(1, pageCount)
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
        guard pendingMeasurementCount == 0 else { return }
        queue.clearChain()
        guard hasLiveWebView else { return }
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

    private func prepareIfNeeded(host: EPUBOffscreenWebViewHost, publication: EPUBPublication,
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
