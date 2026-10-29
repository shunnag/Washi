import XCTest
@testable import Washi

final class CensusPoolExpansionTests: XCTestCase {
    func testShortAndFastBooksStaySerial() {
        // 9〜10 項目を約 0.15 秒で測る実測条件と、起動だけが遅い場合を再現する。
        let prediction = sampled(itemTime: .milliseconds(15), firstItemTime: .seconds(1))
        for spineCount in [9, 10] {
            XCTAssertEqual(prediction.workerCount(remainingItemCount: spineCount - 4, gatedWorkerCount: 4), 1)
        }
        let fast = sampled(itemTime: .milliseconds(1))
        XCTAssertEqual(fast.workerCount(remainingItemCount: 200, gatedWorkerCount: 4), 1)
    }

    func testLongBooksExpandUpToTheGate() {
        let prediction = sampled(itemTime: .milliseconds(15))
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 2_010, gatedWorkerCount: 4), 4)
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 90, gatedWorkerCount: 2), 2)
        let slow = sampled(itemTime: .milliseconds(250))
        XCTAssertEqual(slow.workerCount(remainingItemCount: 2, gatedWorkerCount: 4), 2)
        XCTAssertEqual(slow.workerCount(remainingItemCount: 1, gatedWorkerCount: 4), 1)
        XCTAssertEqual(slow.workerCount(remainingItemCount: 0, gatedWorkerCount: 4), 1)
    }

    func testExpansionRequiresMoreThan400MillisecondsRemaining() {
        let prediction = sampled(itemTime: .milliseconds(25))
        XCTAssertEqual(CensusPoolExpansion.remainingTimeThreshold, .milliseconds(400))
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 15, gatedWorkerCount: 4), 1)
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 16, gatedWorkerCount: 4), 1)
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 17, gatedWorkerCount: 4), 4)
    }

    func testStartsSerialAndExcludesFirstItemUntilThreeWarmSamplesExist() {
        var prediction = CensusPoolExpansion()
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 600, gatedWorkerCount: 4), 1)
        prediction.recordItemTime(.seconds(2))
        for _ in 0..<2 {
            prediction.recordItemTime(.milliseconds(10))
            XCTAssertEqual(prediction.workerCount(remainingItemCount: 600, gatedWorkerCount: 4), 1)
        }
        prediction.recordItemTime(.milliseconds(10))
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 600, gatedWorkerCount: 4), 4)
        XCTAssertEqual(prediction.workerCount(remainingItemCount: 9, gatedWorkerCount: 4), 1)
    }

    func testNeverExpandsUnderConservationPressureLowRAMOrSmallBookGate() {
        let prediction = sampled(itemTime: .seconds(1))
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        for conserving in [false, true] {
            for pressure in [false, true] {
                let gate = CensusConcurrency.workerCount(
                    physicalMemory: 16 * gib, isConserving: conserving,
                    isUnderMemoryPressure: pressure, spineCount: 600)
                XCTAssertEqual(prediction.workerCount(remainingItemCount: 596, gatedWorkerCount: gate),
                               conserving || pressure ? 1 : 4)
            }
        }
        for (ram, spine) in [(4 * gib, 600), (16 * gib, 7)] {
            let gate = CensusConcurrency.workerCount(
                physicalMemory: ram, isConserving: false, isUnderMemoryPressure: false, spineCount: spine)
            XCTAssertEqual(prediction.workerCount(remainingItemCount: spine - 4, gatedWorkerCount: gate), 1)
        }
    }

    private func sampled(itemTime: Duration, firstItemTime: Duration = .seconds(1)) -> CensusPoolExpansion {
        var prediction = CensusPoolExpansion()
        prediction.recordItemTime(firstItemTime)
        for _ in 0..<CensusPoolExpansion.minimumSamples { prediction.recordItemTime(itemTime) }
        return prediction
    }
}
