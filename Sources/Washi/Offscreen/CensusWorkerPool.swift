import Foundation

/// ホスト数の決定だけを切り出し、実機の RAM・省エネ状態に依存せず検証する。
enum CensusConcurrency {
    static func workerCount(physicalMemory: UInt64, isConserving: Bool,
                            isUnderMemoryPressure: Bool, spineCount: Int,
                            maximumWorkers: Int = 4) -> Int {
        guard spineCount >= 8, !isConserving, !isUnderMemoryPressure else { return 1 }
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        let budget = physicalMemory < 8 * gib ? 1 : (physicalMemory < 16 * gib ? 2 : 4)
        return max(1, min(4, budget, maximumWorkers))
    }
}

/// 初回起動を除く項目時間から、追加ホストの起動費を回収できるか判断する。
struct CensusPoolExpansion {
    // 全コーパス実測では計 383 → 243 秒だが、9〜10 項目の本は
    // 0.14〜0.18 → 0.18〜0.29 秒へ悪化し、並列化した 124 条件中 63 条件が遅かった。
    // 残り 400 ms 以下なら起動費を避け、既存の 1 ホストで完走する。
    static let remainingTimeThreshold: Duration = .milliseconds(400)
    static let minimumSamples = 3

    private let threshold: Duration
    private var hasObservedFirstItem = false
    private var sampleCount = 0
    private var sampledTime = Duration.zero

    init(threshold: Duration = Self.remainingTimeThreshold) {
        self.threshold = threshold
    }

    mutating func recordItemTime(_ elapsed: Duration) {
        // 最初の項目には WebContent 起動・初回 JS の費用が混ざるため、予測へ含めない。
        guard hasObservedFirstItem else {
            hasObservedFirstItem = true
            return
        }
        guard elapsed >= .zero else { return }
        sampleCount += 1
        sampledTime += elapsed
    }

    func workerCount(remainingItemCount: Int, gatedWorkerCount: Int) -> Int {
        guard gatedWorkerCount > 1, remainingItemCount > 1,
              sampleCount >= Self.minimumSamples else { return 1 }
        let meanItemTime = sampledTime / sampleCount
        guard meanItemTime * remainingItemCount > threshold else { return 1 }
        return min(gatedWorkerCount, remainingItemCount)
    }
}

/// 完了順に関係なく spine 番号で保持する。中断後に穴より後の値を返さない。
struct CensusIndexedResults {
    private var values: [Int?]
    private(set) var nextIndex: Int
    private(set) var isInterrupted = false

    init(itemCount: Int, prefix: [Int]) {
        let prefix = Array(prefix.prefix(itemCount))
        values = prefix.map(Optional.some) + Array(repeating: nil, count: itemCount - prefix.count)
        nextIndex = prefix.count
    }

    mutating func takeNext() -> Int? {
        guard !isInterrupted, nextIndex < values.count else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }

    mutating func record(_ count: Int, at index: Int) {
        guard !isInterrupted else { return }
        values[index] = count
    }

    mutating func interrupt() { isInterrupted = true }

    var contiguousPrefix: [Int] { values.prefix(while: { $0 != nil }).map { $0! } }
    var isComplete: Bool { !isInterrupted && values.allSatisfy { $0 != nil } }
}

/// 全ワーカーは MainActor 上で cursor を取得し、各 await の後で中断を確認する。
/// 項目計測を差し替えられるので、WebKit なしで中断・取消し・並行数を検証できる。
@MainActor
enum CensusWorkerPool {
    @MainActor
    private final class Work {
        var results: CensusIndexedResults
        init(itemCount: Int, prefix: [Int]) {
            results = CensusIndexedResults(itemCount: itemCount, prefix: prefix)
        }
    }

    static func run(
        itemCount: Int, prefix: [Int], workerCount: Int,
        workerLimit: @escaping @MainActor @Sendable () -> Int,
        isAborted: @escaping @MainActor @Sendable () -> Bool,
        onInterrupt: @escaping @MainActor @Sendable () -> Void,
        onWorkerFinished: @escaping @MainActor @Sendable (Int) -> Void = { _ in },
        measure: @escaping @MainActor @Sendable (Int, Int) async -> Int?
    ) async -> EPUBPaginationCensus.Outcome {
        let work = Work(itemCount: itemCount, prefix: prefix)
        let runWorker: @MainActor @Sendable (Int) async -> Void = { worker in
            defer { onWorkerFinished(worker) }
            while !work.results.isInterrupted {
                guard !Task.isCancelled, !isAborted() else {
                    work.results.interrupt()
                    return
                }
                // 進行中の項目は完了させ、省エネ・圧迫時は追加ホストを退役させる。
                guard worker < workerLimit(), let index = work.results.takeNext() else { return }
                let count = await measure(worker, index)
                guard !Task.isCancelled, !isAborted(), let count else {
                    work.results.interrupt()
                    return
                }
                work.results.record(count, at: index)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workerCount {
                // 最初の JS が低い継承 QoS で応答しなくなるため、全ワーカーで明示する。
                group.addTask(priority: .userInitiated) { await runWorker(worker) }
            }
            var didInterrupt = false
            for await _ in group {
                if work.results.isInterrupted, !didInterrupt {
                    didInterrupt = true
                    group.cancelAll()
                    onInterrupt()
                }
            }
        }
        return .init(counts: work.results.contiguousPrefix, isComplete: work.results.isComplete)
    }
}
