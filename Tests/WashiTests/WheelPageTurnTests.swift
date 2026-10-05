import AppKit
import WebKit
import XCTest
@testable import Washi

/// ホイール/トラックパッドの「1 ジェスチャ = 1 ページ」送り。
/// 縦書きの見開きで章の途中(scrollX が負)にいると、WebKit は wheel を DOM に
/// 渡さず自前でスクロールするため、JS の wheel 処理では送れなかった。
/// 本物の scrollWheel を WashiWebView に当てて確かめる(道具は WheelPageTurnTestSupport)。
@MainActor
final class WheelPageTurnTests: XCTestCase {
    // MARK: テスト 1 — 縦書き見開き・章の途中(修正前は失敗する)

    func testVerticalSpreadMidChapterTurnsWithHorizontalAndVerticalWheel() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.verticalBody(), name: "vrl-spread"),
            double: true)
        defer { harness.close() }
        XCTAssertEqual(harness.view.pagesPerScreen, 2)
        await harness.advance(times: 2)
        XCTAssertEqual(harness.view.pageInItem, 4, "章の途中から始める")
        // この条件(scrollX が負)で WebKit が wheel を DOM に渡さなくなる
        let scrollX = try await harness.scrollX()
        XCTAssertLessThan(scrollX, 0, "縦書きの見開きの章の途中では scrollX が負")

        // 縦書き(右綴じ): 左向き(dx>0)= 先へ、右向き(dx<0)= 戻る
        try await harness.turn(dx: 12, expect: 6, "横ホイール 左向き")
        try await harness.turn(dx: -12, expect: 4, "横ホイール 右向き")
        try await harness.turn(dy: -12, expect: 6, "縦ホイール 下")
        try await harness.turn(dy: 12, expect: 4, "縦ホイール 上")
    }

    // MARK: テスト 2 — 今まで正常だった条件の回帰

    func testOtherLayoutsKeepOneGesturePerPage() async throws {
        let htbSpread = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "htb-spread"),
            double: true)
        defer { htbSpread.close() }
        await htbSpread.advance(times: 2)
        XCTAssertEqual(htbSpread.view.pageInItem, 4)
        // 横書き(左綴じ): 右向き(dx<0)= 先へ
        try await htbSpread.turn(dx: -12, expect: 6, "横書き見開き 横 右向き")
        try await htbSpread.turn(dx: 12, expect: 4, "横書き見開き 横 左向き")
        try await htbSpread.turn(dy: -12, expect: 6, "横書き見開き 縦 下")

        let vrlSingle = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.verticalBody(), name: "vrl-single"),
            double: false)
        defer { vrlSingle.close() }
        await vrlSingle.advance(times: 2)
        XCTAssertEqual(vrlSingle.view.pageInItem, 2)
        try await vrlSingle.turn(dx: 12, expect: 3, "縦書き単ページ 横 左向き")
        try await vrlSingle.turn(dx: -12, expect: 2, "縦書き単ページ 横 右向き")
        try await vrlSingle.turn(dy: -12, expect: 3, "縦書き単ページ 縦 下")

        let htbSingle = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "htb-single"),
            double: false)
        defer { htbSingle.close() }
        await htbSingle.advance(times: 2)
        XCTAssertEqual(htbSingle.view.pageInItem, 2)
        try await htbSingle.turn(dx: -12, expect: 3, "横書き単ページ 横 右向き")
        try await htbSingle.turn(dy: 12, expect: 2, "横書き単ページ 縦 上")
    }

    /// トラックパッドは指を置いた時点で移動量 0 のイベント(mayBegin)を送る。
    /// それで軸を決めると縦になり、続く横スワイプで送れなくなる
    func testMayBeginBeforeHorizontalSwipeStillTurns() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "may-begin"),
            double: false)
        defer { harness.close() }
        await harness.advance(times: 2)
        XCTAssertEqual(harness.view.pageInItem, 2)
        // kCGScrollPhaseMayBegin = 128
        let mayBegin = try XCTUnwrap(harness.scrollEvent(dx: 0, dy: 0, phase: 128))
        harness.webView.scrollWheel(with: mayBegin)
        try await Task.sleep(for: .milliseconds(30))
        try await harness.turn(dx: -12, expect: 3, "指を置いてからの横スワイプ 右向き")
    }

    // MARK: テスト 3 — 横方向の 2 設定

    func testHorizontalWheelSettingsGateAndReverse() async throws {
        let gated = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "gated"),
            double: false) {
            $0.horizontalWheelTurnsPages = false
        }
        defer { gated.close() }
        await gated.advance(times: 2)
        let start = gated.view.pageInItem
        try await gated.gesture(dx: -12)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(gated.view.pageInItem, start, "横方向の送りが OFF なら横ホイールでは送らない")
        try await gated.turn(dy: -12, expect: start + 1, "OFF でも縦ホイールでは送る")

        let reversed = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "reversed"),
            double: false) {
            $0.reversesHorizontalWheelTurn = true
        }
        defer { reversed.close() }
        await reversed.advance(times: 2)
        XCTAssertEqual(reversed.view.pageInItem, 2)
        try await reversed.turn(dx: -12, expect: 1, "反転: 右向きで戻る")
    }

    // MARK: テスト 4 — スクロール表示は WebKit に任せる

    func testScrolledFlowLeavesWheelToWebKit() async throws {
        let harness = try await WheelHarness.make(
            try scrollPublication(flow: "scrolled-doc"), double: false)
        defer { harness.close() }
        // scrollY が増えるだけでは足りない(native が横取りしても goForward が
        // 1 画面スクロールするので増える)。wheel が DOM まで届いたことを数える
        try await harness.runJS("""
            globalThis.__wheelCount = 0;
            window.addEventListener('wheel', () => { globalThis.__wheelCount += 1; },
                                    { capture: true, passive: true });
            return 0;
            """)
        let before = try await harness.scrollY()
        try await harness.gesture(dy: -12)
        try await Task.sleep(for: .milliseconds(600))
        let after = try await harness.scrollY()
        XCTAssertGreaterThan(after, before, "スクロール表示では WebKit がスクロールする")
        let wheelCount = try await harness.runJS("return globalThis.__wheelCount;")
        XCTAssertGreaterThan(wheelCount, 0, "スクロール表示では wheel が WebKit(DOM)に届く")
    }

    // MARK: テスト 5 — 章をまたいだ直後の慣性で余分に送らない

    /// 5a: 章の最後から送ったジェスチャの続き(慣性)で、次の章をもう 1 ページ送らない
    func testMomentumAfterCrossingChapterDoesNotTurnAgain() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.twoChapterPublication(), double: false,
            at: EPUBLocator(spineIndex: 0, progression: 1))
        defer { harness.close() }
        XCTAssertEqual(harness.view.currentSpineIndex, 0)
        // 約 0.5 秒続く 1 ジェスチャ(最初の数イベントで閾値を超え、残りは慣性相当)
        try await harness.gesture(dy: -12, changes: 30)
        let crossed = await waitUntil(timeout: .seconds(3)) { harness.view.currentSpineIndex == 1 }
        XCTAssertTrue(crossed, "次の章へ送られる")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.view.currentSpineIndex, 1)
        XCTAssertEqual(harness.view.pageInItem, 0, "慣性で次の章をさらに送らない")
    }

    /// 5b: ホイール以外(キー等)で章をまたいだ直後に続くホイールでは送らず、
    /// 0.25 秒静かになってからのジェスチャで送る
    func testWheelRightAfterChapterLoadIsIgnoredUntilQuiet() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.twoChapterPublication(), double: false,
            at: EPUBLocator(spineIndex: 0, progression: 1))
        defer { harness.close() }
        harness.view.goForward()
        try await harness.gesture(dy: -12, changes: 12)
        _ = await waitUntil(timeout: .seconds(3)) { harness.view.currentSpineIndex == 1 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.view.currentSpineIndex, 1)
        XCTAssertEqual(harness.view.pageInItem, 0, "読み込みの直後に続くホイールでは送らない")
        try await harness.turn(dy: -12, expect: 1, "静かになってからのジェスチャでは送る")
    }

    /// 5c: 読み込みの間にホイールが無くても、読み込みの直後(開始から 0.25 秒以内)に
    /// 来たホイールでは送らない(読み込み開始時のラッチだけが守る)。
    /// 読み込みにかかる実時間に左右されないよう、ホイールの時刻を読み込み開始時の
    /// ラッチの時刻からの相対で付ける
    func testWheelJustAfterChapterLoadWithoutEarlierWheelDoesNotTurn() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.twoChapterPublication(), double: false,
            at: EPUBLocator(spineIndex: 0, progression: 1))
        defer { harness.close() }
        let movesBefore = harness.spy.moveCount
        let latchBefore = harness.view.wheelTurnLatch.lastTime
        harness.view.goForward()
        let loaded = await waitUntil(timeout: .seconds(3)) {
            harness.spy.moveCount > movesBefore && harness.view.currentSpineIndex == 1
                && !harness.view.spineLoad.isLoadingSpineItem
        }
        XCTAssertTrue(loaded, "次の章が読み込まれる")
        // 読み込み開始がラッチを掛け、その時刻を記録している(この間ホイールは無い)
        let latch = harness.view.wheelTurnLatch
        XCTAssertTrue(latch.latched, "読み込み開始でラッチする")
        XCTAssertGreaterThan(latch.lastTime, latchBefore, "読み込み開始の時刻を記録する")
        // 読み込み開始から 0.05〜0.13 秒の時刻のジェスチャ(移動量は閾値を超える)
        try await harness.gesture(dy: -12, changes: 4, startingAt: latch.lastTime + 0.05)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.view.currentSpineIndex, 1)
        XCTAssertEqual(harness.view.pageInItem, 0, "読み込み開始から 0.25 秒以内のホイールでは送らない")
        // 対照: 同じ文書・同じ移動量のジェスチャでも、静かになってからなら送る
        try await harness.turn(dy: -12, expect: 1, "静かになってからのジェスチャでは送る")
    }

    // MARK: テスト 6 — 「ホイールでページを送る」OFF

    func testWheelTurnsPagesOffDiscardsPaginatedWheelWithoutScrolling() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.verticalBody(), name: "wheel-off"),
            double: true) {
            $0.wheelTurnsPages = false
        }
        defer { harness.close() }
        await harness.advance(times: 2)
        XCTAssertEqual(harness.view.pageInItem, 4, "章の途中(scrollX が負)から始める")
        // scrollX が同じでも「スクロールして戻った」可能性は消せない。scroll イベントを数える
        // (capture で要素のスクロールも拾う)。ジェスチャの始まりと終わりは移動量 0 の
        // 複製が WebKit に渡るので、それでもスクロールしないことも確かめる
        try await harness.runJS("""
            globalThis.__scrollCount = 0;
            window.addEventListener('scroll', () => { globalThis.__scrollCount += 1; },
                                    { capture: true, passive: true });
            return 0;
            """)
        let before = try await harness.scrollX()
        try await harness.gesture(dx: 12)
        try await Task.sleep(for: .milliseconds(400))
        try await harness.gesture(dy: -12)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.view.pageInItem, 4, "OFF なら縦横とも送らない")
        let after = try await harness.scrollX()
        XCTAssertEqual(after, before, "OFF でも WebKit に渡さない(スクロールして戻る動きを出さない)")
        let scrollCount = try await harness.runJS("return globalThis.__scrollCount;")
        XCTAssertEqual(scrollCount, 0, "OFF の間は一度もスクロールしない")

        harness.view.settings.wheelTurnsPages = true
        try await Task.sleep(for: .milliseconds(400))
        try await harness.turn(dx: 12, expect: 6, "ON に戻すと送る")
        // 数える仕組みが働いていることの確認(送ればスクロールが起きる)
        let scrollCountAfterTurn = try await harness.runJS("return globalThis.__scrollCount;")
        XCTAssertGreaterThan(scrollCountAfterTurn, 0, "送ったときは scroll イベントを数える")
    }

    func testWheelTurnsPagesOffKeepsScrolledFlowScrolling() async throws {
        let harness = try await WheelHarness.make(
            try scrollPublication(flow: "scrolled-doc"), double: false) {
            $0.wheelTurnsPages = false
        }
        defer { harness.close() }
        let before = try await harness.scrollY()
        try await harness.gesture(dy: -12)
        try await Task.sleep(for: .milliseconds(600))
        let after = try await harness.scrollY()
        XCTAssertGreaterThan(after, before, "OFF でもスクロール表示は WebKit がスクロールする")
    }
}
