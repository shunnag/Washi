import XCTest
@testable import Washi

final class CensusConcurrencyTests: XCTestCase {
    func testRAMBoundariesAndWorkerCap() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        for (ram, expected): (UInt64, Int) in [
            (0, 1), (8 * gib - 1, 1), (8 * gib, 2), (16 * gib - 1, 2),
            (16 * gib, 4), (128 * gib, 4)
        ] {
            XCTAssertEqual(CensusConcurrency.workerCount(
                physicalMemory: ram, isConserving: false,
                isUnderMemoryPressure: false, spineCount: 8), expected)
        }
        for maximum in [0, 1, 2, 3, 4, 9] {
            XCTAssertEqual(CensusConcurrency.workerCount(
                physicalMemory: 32 * gib, isConserving: false,
                isUnderMemoryPressure: false, spineCount: 8, maximumWorkers: maximum),
                max(1, min(4, maximum)))
        }
    }

    func testConservationPressureAndSmallBooksAlwaysUseOneWorker() {
        for conserving in [false, true] {
            for pressure in [false, true] {
                for spine in 0...9 {
                    XCTAssertEqual(CensusConcurrency.workerCount(
                        physicalMemory: 64 * 1_024 * 1_024 * 1_024,
                        isConserving: conserving, isUnderMemoryPressure: pressure,
                        spineCount: spine), conserving || pressure || spine < 8 ? 1 : 4)
                }
            }
        }
    }

    func testAllCompletionOrdersReturnOnlyAContiguousPrefix() {
        func permutations(_ indices: [Int]) -> [[Int]] {
            if indices.isEmpty { return [[]] }
            return indices.flatMap { first in
                permutations(indices.filter { $0 != first }).map { [first] + $0 }
            }
        }
        let expected = [7, 11, 13, 17, 19, 23]
        for order in permutations([2, 3, 4, 5]) {
            for stop in 0...4 {
                var results = CensusIndexedResults(itemCount: 6, prefix: [7, 11])
                XCTAssertEqual((0..<4).compactMap { _ in results.takeNext() }, [2, 3, 4, 5])
                XCTAssertNil(results.takeNext())
                for index in order.prefix(stop) { results.record(expected[index], at: index) }
                let prefix = results.contiguousPrefix
                XCTAssertEqual(prefix, Array(expected.prefix(prefix.count)))
                if stop < 4 {
                    results.interrupt()
                    for index in order.dropFirst(stop) { results.record(expected[index], at: index) }
                    XCTAssertEqual(results.contiguousPrefix, prefix)
                    XCTAssertFalse(results.isComplete)
                    XCTAssertNil(results.takeNext())
                    var resumed = CensusIndexedResults(itemCount: 6, prefix: prefix)
                    while let index = resumed.takeNext() { resumed.record(expected[index], at: index) }
                    XCTAssertEqual(resumed.contiguousPrefix, expected)
                    XCTAssertTrue(resumed.isComplete)
                } else {
                    XCTAssertTrue(results.isComplete)
                }
            }
        }
    }

    func testOversizedAndEmptyPrefixes() {
        let empty = CensusIndexedResults(itemCount: 0, prefix: [5])
        XCTAssertEqual(empty.contiguousPrefix, [])
        XCTAssertTrue(empty.isComplete)
        var full = CensusIndexedResults(itemCount: 2, prefix: [5, 6, 7])
        XCTAssertEqual(full.contiguousPrefix, [5, 6])
        XCTAssertNil(full.takeNext())
        XCTAssertTrue(full.isComplete)
    }
}

@MainActor
final class CensusWorkerPoolTests: XCTestCase {
    func testCensusBudgetAndMissingItemShortcutWithoutWebKit() async throws {
        let entries = EPUBFixtures.reflowSpreadEntries(renditionSpread: .none, bodyHTML: "")
            .filter { !$0.name.hasSuffix(".xhtml") }
            .map { entry in
                guard entry.name.hasSuffix(".opf") else { return entry }
                let opf = String(decoding: entry.data, as: UTF8.self).replacingOccurrences(
                    of: "<itemref idref=\"c\"/>", with: String(repeating: "<itemref idref=\"c\"/>", count: 8))
                return (name: entry.name, data: Data(opf.utf8))
            }
        let publication = try EPUBFixtures.publication(entries, name: "washi-census-pool-missing")
        let metrics = EPUBScreenMetrics(viewportSize: CGSize(width: 800, height: 600),
                                        settings: EPUBReaderSettings())
        for (ram, pressure, conserving) in [
            (4, false, false), (8, false, false), (16, false, false),
            (16, true, false), (16, false, true)
        ] {
            let pacer = EPUBOffscreenEnergyPacer(state: { .init(isLowPowerModeEnabled: conserving) })
            pacer.policy = .followSystem
            let census = EPUBPaginationCensus(
                energyPacer: pacer,
                resourceBudget: { (UInt64(ram) * 1_024 * 1_024 * 1_024, pressure) })
            let outcome = await census.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                                contentSize: metrics.contentSize, resuming: [])
            XCTAssertEqual(outcome, .init(counts: Array(repeating: 1, count: 8), isComplete: true))
            XCTAssertEqual(census.lastWorkerCount, 1)
            XCTAssertEqual(census.loadedItemCount, 0)
            XCTAssertEqual(census.liveWebViewCount, 0)
            census.invalidate()
        }
    }

    func testEnergyGateMatchesPolicyAndDoesNotReadStateWhenUnrestricted() {
        var state = EPUBOffscreenSystemEnergyState()
        var reads = 0
        let pacer = EPUBOffscreenEnergyPacer(state: { reads += 1; return state })
        for lowPower in [false, true] {
            for thermal: ProcessInfo.ThermalState in [.nominal, .fair, .serious, .critical] {
                state = .init(isLowPowerModeEnabled: lowPower, thermalState: thermal)
                pacer.policy = .unrestricted
                let before = reads
                XCTAssertFalse(pacer.isConserving)
                XCTAssertEqual(reads, before)
                pacer.policy = .followSystem
                XCTAssertEqual(pacer.isConserving, lowPower || thermal == .serious || thermal == .critical)
            }
        }
    }

    func testInvalidationWhileAwaitingDropsLateResultAndReleasesAllWorkers() async {
        let gate = ItemGate()
        var aborted = false
        var released = 0
        let task = Task {
            await CensusWorkerPool.run(
                itemCount: 8, prefix: [], workerCount: 4, workerLimit: { 4 },
                isAborted: { aborted }, onInterrupt: { released += 1; gate.finishAll() },
                measure: { await gate.measure(worker: $0, index: $1) })
        }
        await gate.waitForStarted(4)
        aborted = true
        gate.finish(0, count: 100)
        let result = await task.value
        XCTAssertEqual(result, .init(counts: [], isComplete: false))
        XCTAssertEqual(released, 1)
        XCTAssertTrue(gate.pending.isEmpty)
    }

    /// 後ろの項目が先に完了しても、前方の失敗で穴の後ろを返さない。
    func testOutOfOrderFailureCancelsSiblingsAndResumesFromPrefix() async {
        let gate = ItemGate()
        var interrupted = 0
        // 親の優先度の継承だけでは通らないよう、低い基底優先度から呼ぶ。
        let task = Task(priority: .background) {
            await CensusWorkerPool.run(
                itemCount: 8, prefix: [10], workerCount: 4, workerLimit: { 4 },
                isAborted: { false }, onInterrupt: { interrupted += 1; gate.finishAll() },
                measure: { worker, index in
                    // CI の QoS clamp は実効優先度を変えるため、要求した基底優先度を確かめる。
                    XCTAssertEqual(withUnsafeCurrentTask { $0?.basePriority }, TaskPriority.userInitiated)
                    return await gate.measure(worker: worker, index: index)
                })
        }
        await gate.waitForStarted(4)
        gate.finish(2, count: 12)
        await gate.waitForStarted(5)
        gate.finish(1, count: 11)
        await gate.waitForStarted(6)
        gate.finish(4, count: 14)
        await gate.waitForStarted(7)
        gate.finish(3, count: nil)
        let result = await task.value
        XCTAssertEqual(result, .init(counts: [10, 11, 12], isComplete: false))
        XCTAssertEqual(interrupted, 1)

        var loaded: [Int] = []
        let resumed = await CensusWorkerPool.run(
            itemCount: 8, prefix: result.counts, workerCount: 4, workerLimit: { 4 },
            isAborted: { false }, onInterrupt: {}, measure: { _, index in
                loaded.append(index)
                return 10 + index
            })
        XCTAssertEqual(resumed, .init(counts: Array(10...17), isComplete: true))
        XCTAssertEqual(loaded.sorted(), Array(3...7))
    }

    func testBudgetReductionRetiresExtraWorkersAndPrimaryDrainsCursor() async {
        let gate = ItemGate()
        var limit = 4
        let task = Task {
            await CensusWorkerPool.run(
                itemCount: 8, prefix: [], workerCount: 4, workerLimit: { limit },
                isAborted: { false }, onInterrupt: { gate.finishAll() },
                measure: { await gate.measure(worker: $0, index: $1) })
        }
        await gate.waitForStarted(4)
        limit = 1
        for index in 0..<4 { gate.finish(index, count: index + 1) }
        for count in 5...8 {
            await gate.waitForStarted(count)
            let index = count - 1
            XCTAssertEqual(gate.workers[index], 0)
            gate.finish(index, count: count)
        }
        let result = await task.value
        XCTAssertEqual(result, .init(counts: Array(1...8), isComplete: true))
    }

    func testCancellationReleasesWorkersAndReturnsOnlyCompletedPrefix() async {
        let gate = ItemGate()
        var interrupts = 0
        let task = Task {
            await CensusWorkerPool.run(
                itemCount: 8, prefix: [9], workerCount: 4, workerLimit: { 4 },
                isAborted: { false }, onInterrupt: { interrupts += 1; gate.finishAll() },
                measure: { await gate.measure(worker: $0, index: $1) })
        }
        await gate.waitForStarted(4)
        task.cancel()
        gate.finish(1, count: 10)
        let result = await task.value
        XCTAssertEqual(result, .init(counts: [9], isComplete: false))
        XCTAssertEqual(interrupts, 1)
        XCTAssertTrue(gate.pending.isEmpty)
    }

    /// continuation で順序を指定し、実時間やスケジューラの実行順に依存しない。
    @MainActor
    private final class ItemGate {
        var pending: [Int: CheckedContinuation<Int?, Never>] = [:]
        var workers: [Int: Int] = [:]
        var started = 0
        var observer: (Int, CheckedContinuation<Void, Never>)?

        func measure(worker: Int, index: Int) async -> Int? {
            await withCheckedContinuation { continuation in
                pending[index] = continuation
                workers[index] = worker
                started += 1
                if let (count, continuation) = observer, started >= count {
                    observer = nil
                    continuation.resume()
                }
            }
        }

        func waitForStarted(_ count: Int) async {
            if started >= count { return }
            await withCheckedContinuation { observer = (count, $0) }
        }

        func finish(_ index: Int, count: Int?) { pending.removeValue(forKey: index)?.resume(returning: count) }
        func finishAll() {
            let pending = pending
            self.pending.removeAll()
            for continuation in pending.values { continuation.resume(returning: nil) }
        }
    }
}
