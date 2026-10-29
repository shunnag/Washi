import AppKit
import XCTest
@testable import Washi

/// sandbox 外の GUI セッションで WASHI_CENSUS_POOL_WEBKIT=1 を指定した場合だけ実行する。
@MainActor
final class CensusPoolWebKitTests: XCTestCase {
    func testPoolMatchesSerialIdleReleasesEveryHostAndRebuilds() async throws {
        try requireOptIn()
        let publication = try makePublication()
        let metrics = makeMetrics()
        let serial = makeCensus(maximumWorkers: 1)
        let idle = ManualOffscreenIdleScheduler()
        let pool = EPUBPaginationCensus(idleTimerScheduler: idle.scheduler, resourceBudget: Self.budget, poolExpansionThreshold: .zero)
        defer { serial.invalidate(); pool.invalidate() }
        let baseline = await serial.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                            contentSize: metrics.contentSize)
        XCTAssertNotNil(baseline)
        let counts = await pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                        contentSize: metrics.contentSize)
        XCTAssertEqual(counts, baseline)
        XCTAssertEqual(pool.lastWorkerCount, 4)
        XCTAssertEqual(pool.liveWebViewCount, 4)
        idle.advance(by: .seconds(20))
        XCTAssertEqual(pool.liveWebViewCount, 0)
        let rebuilt = await pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                         contentSize: metrics.contentSize)
        XCTAssertEqual(rebuilt, baseline)
        pool.invalidate()
        XCTAssertEqual(pool.liveWebViewCount, 0)
    }

    func testPoolInterruptionReturnsPrefixAndResumeMatchesSerial() async throws {
        try requireOptIn()
        let publication = try makePublication()
        let metrics = makeMetrics()
        let serial = makeCensus(maximumWorkers: 1)
        defer { serial.invalidate() }
        let measured = await serial.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON, contentSize: metrics.contentSize)
        let full = try XCTUnwrap(measured)
        let trigger = TriggeringSetupScheduler()
        trigger.triggerAtScheduleCount = 6
        let pool = EPUBPaginationCensus(javaScriptTimeoutScheduler: trigger.scheduler,
                                        resourceBudget: Self.budget, poolExpansionThreshold: .zero)
        defer { pool.invalidate() }
        trigger.onTrigger = { [weak pool] in pool?.invalidate() }
        let interrupted = await pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                              contentSize: metrics.contentSize, resuming: [])
        XCTAssertFalse(interrupted.isComplete)
        XCTAssertEqual(interrupted.counts, Array(full.prefix(interrupted.counts.count)))
        XCTAssertEqual(pool.liveWebViewCount, 0)
        let before = pool.loadedItemCount
        let resumed = await pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                         contentSize: metrics.contentSize, resuming: interrupted.counts)
        XCTAssertEqual(resumed, .init(counts: full, isComplete: true))
        XCTAssertEqual(pool.loadedItemCount - before, full.count - interrupted.counts.count)
    }

    func testCancellationClosesAllHostsAndEveryFirstSetupUsesUserInitiated() async throws {
        try requireOptIn()
        let publication = try makePublication()
        let metrics = makeMetrics()
        var task: Task<EPUBPaginationCensus.Outcome, Never>?
        var priorities: [TaskPriority] = []
        let pool = EPUBPaginationCensus(javaScriptTimeoutScheduler: { delay, action in
            priorities.append(Task.currentPriority)
            if priorities.count == 7 { task?.cancel() }
            return EPUBOffscreenIdleReleaseTimer.continuousScheduler(delay, action)
        }, resourceBudget: Self.budget, poolExpansionThreshold: .zero)
        defer { pool.invalidate(); task = nil }
        task = Task(priority: .background) {
            await pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                               contentSize: metrics.contentSize, resuming: [])
        }
        let outcome = await task!.value
        XCTAssertFalse(outcome.isComplete)
        XCTAssertGreaterThanOrEqual(priorities.count, 7)
        XCTAssertTrue(priorities.allSatisfy { $0 >= .userInitiated })
        XCTAssertEqual(pool.liveWebViewCount, 0)
    }

    func testConcurrentMeasuresDoNotShareInFlightNavigation() async throws {
        try requireOptIn()
        let publication = try makePublication()
        let metrics = makeMetrics()
        let pool = makeCensus(maximumWorkers: 4)
        defer { pool.invalidate() }
        async let first = pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                       contentSize: metrics.contentSize)
        async let second = pool.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                        contentSize: metrics.contentSize)
        let results = await (first, second)
        XCTAssertNotNil(results.0)
        XCTAssertEqual(results.0, results.1)
        XCTAssertEqual(pool.loadedItemCount, 24)
    }

    private static let budget: @MainActor () -> (physicalMemory: UInt64, isUnderPressure: Bool) = {
        (16 * 1_024 * 1_024 * 1_024, false)
    }

    private func makeCensus(maximumWorkers: Int) -> EPUBPaginationCensus {
        EPUBPaginationCensus(maximumWorkers: maximumWorkers, resourceBudget: Self.budget, poolExpansionThreshold: .zero)
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["WASHI_CENSUS_POOL_WEBKIT"] == "1" else {
            throw XCTSkip("sandbox 外で WASHI_CENSUS_POOL_WEBKIT=1 を指定してください")
        }
    }

    private func makeMetrics() -> EPUBScreenMetrics {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        settings.fontScale = 1.25
        return EPUBScreenMetrics(viewportSize: CGSize(width: 420, height: 600), settings: settings)
    }

    private func makePublication() throws -> EPUBPublication {
        let entries = EPUBFixtures.reflowSpreadEntries(
            renditionSpread: .none, bodyHTML: "<p>\(String(repeating: "Pagination pool test. ", count: 700))</p>")
            .map { entry in
                if entry.name.hasSuffix(".opf") {
                    let opf = String(decoding: entry.data, as: UTF8.self).replacingOccurrences(
                        of: "<itemref idref=\"c\"/>",
                        with: String(repeating: "<itemref idref=\"c\"/>", count: 12))
                    return (name: entry.name, data: Data(opf.utf8))
                }
                return entry
            }
        return try EPUBFixtures.publication(entries, name: "washi-census-pool")
    }
}
