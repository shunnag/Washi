import AppKit
import WebKit
import XCTest
@testable import Washi

// SpineNavigationGate の帳簿: 打ち切った読み込みの遅配の取り消し、setup 完了や
// WebContent プロセスの終了後に残す期待値、同じパスの再発行の順序。
// 実際のリーダーでの失敗と復旧は SpineLoadFailureRecoveryTests を参照

@MainActor
final class SpineLoadPolicyBookkeepingTests: XCTestCase {
    func testAbandonedSpineLoadPoliciesAreCancelledOnce() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml", generation: 1)
        gate.expect("OEBPS/text/ch2.xhtml", generation: 2)
        gate.abandonPendingExpectations()

        // 打ち切った全要求の遅配を、文書由来の移動へ戻さず一度ずつ取り消す。
        for path in ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch2.xhtml"] {
            XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
            XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .routeThroughReader)
        }
    }

    func testAbandonedSpineLoadPolicyPrecedesExpectedLoadForSamePath() {
        var gate = SpineNavigationGate()
        let path = "OEBPS/text/ch1.xhtml"
        gate.expect(path, generation: 1)
        gate.abandonPendingExpectations()
        gate.expect(path, generation: 2)

        // 同じパスの古い読み込みが先に届く。古い要求を許可して新しい復旧を止めない。
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .routeThroughReader)
    }

    func testChainedRecoveriesKeepPolicyIssueOrder() {
        var gate = SpineNavigationGate()
        let origin = "OEBPS/text/ch1.xhtml"
        let first = "OEBPS/text/ch2.xhtml"
        let second = "OEBPS/text/colophon.xhtml"
        gate.expect(first, generation: 1)
        gate.abandonPendingExpectations()
        gate.expect(origin, generation: 2)  // 最初の復旧。
        gate.expect(second, generation: 3)  // 利用者の移動が復旧を置き換える。
        gate.abandonPendingExpectations()
        gate.expect(origin, generation: 4)  // 同じパスへの二度目の復旧。

        for path in [first, origin, second] {
            XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
        }
        XCTAssertEqual(gate.disposition(for: origin, navigationType: .other), .allowExpectedLoad)
    }

    func testSetupCompletionDropsOldExpectationsAndKeepsLaterLoads() {
        var gate = SpineNavigationGate()
        let abandoned = "OEBPS/text/ch2.xhtml"
        let stale = "OEBPS/text/stale.xhtml"
        let shared = "OEBPS/text/ch1.xhtml"
        let expected = "OEBPS/text/colophon.xhtml"
        gate.expect(abandoned, generation: 1)
        gate.abandonPendingExpectations()
        gate.expect(stale, generation: 2)
        gate.expect(shared, generation: 3)
        // setup の通知から始まった次の移動の期待値は、同じパスでも消さない。
        gate.expect(shared, generation: 4)
        gate.expect(expected, generation: 5)
        gate.dropExpectations(through: 3)

        XCTAssertEqual(gate.disposition(for: abandoned, navigationType: .other), .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: stale, navigationType: .other), .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: shared, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: shared, navigationType: .other), .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: expected, navigationType: .other), .allowExpectedLoad)
    }

    func testSetupCompletionKeepsLaterAbandonedExpectations() {
        var gate = SpineNavigationGate()
        let old = "OEBPS/text/ch1.xhtml"
        let later = "OEBPS/text/ch2.xhtml"
        gate.expect(old, generation: 1)
        gate.expect(later, generation: 2)
        gate.abandonPendingExpectations()
        gate.expect(later, generation: 3)

        gate.dropExpectations(through: 1)

        XCTAssertEqual(gate.disposition(for: old, navigationType: .other), .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: later, navigationType: .other), .cancelAbandonedLoad)
        XCTAssertEqual(gate.disposition(for: later, navigationType: .other), .allowExpectedLoad)
    }

    func testTerminatedProcessKeepsQueuedPoliciesCancellableUntilNextLoad() {
        var gate = SpineNavigationGate()
        let queued = "OEBPS/text/ch1.xhtml"
        let lost = "OEBPS/text/ch2.xhtml"
        gate.expect(queued, generation: 1)
        gate.expect(lost, generation: 2)

        gate.abandonForProcessTermination()

        // UI プロセスに届いていた判定は、次の読み込みまで取り消せる。
        XCTAssertEqual(gate.disposition(for: queued, navigationType: .other), .cancelAbandonedLoad)
        gate.dropTerminatedProcessExpectations()
        XCTAssertEqual(gate.disposition(for: lost, navigationType: .other), .routeThroughReader)
        gate.expect(lost, generation: 3)
        XCTAssertEqual(gate.disposition(for: lost, navigationType: .other), .allowExpectedLoad)
    }

    func testTerminatedProcessPurgeKeepsNewerLoadsAfterPoliciesAreConsumed() {
        var gate = SpineNavigationGate()
        let shared = "OEBPS/text/ch1.xhtml"
        let queued = "OEBPS/text/ch2.xhtml"
        gate.expect(shared, generation: 1)
        gate.expect(queued, generation: 2)
        gate.abandonForProcessTermination()
        gate.expect(shared, generation: 3)
        XCTAssertEqual(gate.disposition(for: queued, navigationType: .other), .cancelAbandonedLoad)

        // 途中で古い期待値が消費されても、件数で後の読み込みまで消してはいけない。
        gate.dropTerminatedProcessExpectations()
        XCTAssertEqual(gate.disposition(for: shared, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: shared, navigationType: .other), .routeThroughReader)
        gate.expect(shared, generation: 4)
        gate.abandonPendingExpectations()
        gate.dropTerminatedProcessExpectations()
        XCTAssertEqual(gate.disposition(for: shared, navigationType: .other), .cancelAbandonedLoad)
    }

    func testCancellingExpectedSpineLoadKeepsAbandonedEntries() {
        var gate = SpineNavigationGate()
        let path = "OEBPS/text/ch1.xhtml"
        gate.expect(path, generation: 1)
        gate.abandonPendingExpectations()
        gate.expect(path, generation: 2)
        gate.expect(path, generation: 3)
        gate.cancelExpectation(for: path)

        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .routeThroughReader)

        gate.expect(path, generation: 4)
        gate.abandonPendingExpectations()
        gate.cancelExpectation(for: path)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
    }

    func testUnknownSpineLoadPolicyStillRoutesAfterAbandonment() {
        var gate = SpineNavigationGate()
        let abandoned = "OEBPS/text/ch2.xhtml"
        let recovery = "OEBPS/text/ch1.xhtml"
        gate.expect(abandoned, generation: 1)
        gate.abandonPendingExpectations()
        gate.expect(recovery, generation: 2)

        XCTAssertEqual(gate.disposition(for: "OEBPS/text/other.xhtml", navigationType: .other),
                       .routeThroughReader)
        // 明示的なリンクは従来どおり移動させ、遅配の取消枠を消費しない。
        XCTAssertEqual(gate.disposition(for: abandoned, navigationType: .linkActivated),
                       .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: recovery, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: abandoned, navigationType: .other), .cancelAbandonedLoad)
    }
}
