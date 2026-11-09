import XCTest
@testable import Washi

/// census 失敗台帳(2-strike + TTL)の検証。now を注入して完全決定論(sleep 不要)。
final class CensusFailureLedgerTests: XCTestCase {
    func testTwoStrikesThenSkip() {
        var ledger = CensusFailureLedger(ttl: .seconds(300))
        let t0 = ContinuousClock.now
        XCTAssertFalse(ledger.shouldSkip("k", now: t0))  // 未記録
        ledger.recordFailure("k", now: t0)
        XCTAssertFalse(ledger.shouldSkip("k", now: t0))  // 1 回では止めない
        ledger.recordFailure("k", now: t0)
        XCTAssertTrue(ledger.shouldSkip("k", now: t0))   // 2 回で恒久記録
    }

    func testForgivenAfterTTL() {
        var ledger = CensusFailureLedger(ttl: .seconds(300))
        let t0 = ContinuousClock.now
        ledger.recordFailure("k", now: t0)
        ledger.recordFailure("k", now: t0)
        XCTAssertTrue(ledger.shouldSkip("k", now: t0))
        // TTL 経過で赦す
        let later = t0.advanced(by: .seconds(301))
        XCTAssertFalse(ledger.shouldSkip("k", now: later))
        // 勘定リセット後は 1 回失敗しても再 skip しない
        ledger.recordFailure("k", now: later)
        XCTAssertFalse(ledger.shouldSkip("k", now: later))
    }

    func testClearResets() {
        var ledger = CensusFailureLedger(ttl: .seconds(300))
        let t0 = ContinuousClock.now
        ledger.recordFailure("k", now: t0)
        ledger.recordFailure("k", now: t0)
        XCTAssertTrue(ledger.shouldSkip("k", now: t0))
        ledger.clear()
        XCTAssertFalse(ledger.shouldSkip("k", now: t0))
    }

    func testRecordCountIsBoundedInInsertionOrder() {
        var ledger = CensusFailureLedger(limit: 3)
        let t0 = ContinuousClock.now
        for index in 0..<5 {
            ledger.recordFailure("k\(index)", now: t0)
            ledger.recordFailure("k\(index)", now: t0)
        }
        XCTAssertEqual(ledger.count, 3)
        XCTAssertFalse(ledger.shouldSkip("k0", now: t0))
        XCTAssertFalse(ledger.shouldSkip("k1", now: t0))
        XCTAssertTrue(ledger.shouldSkip("k2", now: t0))
        XCTAssertTrue(ledger.shouldSkip("k4", now: t0))
    }

    func testHugeCSSKeysRemainDistinctWithoutRetainingRawKeys() {
        var ledger = CensusFailureLedger(limit: 3)
        let t0 = ContinuousClock.now
        let prefix = String(repeating: "body { font-family: x; }", count: 10_000)
        for suffix in ["a", "b"] {
            ledger.recordFailure(prefix + suffix, now: t0)
            ledger.recordFailure(prefix + suffix, now: t0)
        }
        XCTAssertTrue(ledger.shouldSkip(prefix + "a", now: t0))
        XCTAssertTrue(ledger.shouldSkip(prefix + "b", now: t0))
        XCTAssertEqual(ledger.count, 2)
        XCTAssertLessThanOrEqual(ledger.retainedKeyByteCount, 2 * 64)
    }
}
