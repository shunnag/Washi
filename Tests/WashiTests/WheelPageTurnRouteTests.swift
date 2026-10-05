import AppKit
import WebKit
import XCTest
@testable import Washi

/// ホイールの送りの配送経路: 右綴じの横書き、当たり判定で選ばれたビュー、
/// めくりのカバーの上、WebKit へ渡す移動量 0 の複製、読み込み中のフロー切り替え
/// (道具は WheelPageTurnTestSupport)
@MainActor
final class WheelPageTurnRouteTests: XCTestCase {
    // MARK: 右綴じの横書き(dir=rtl)

    func testRTLHorizontalPaginatedTurnsInReadingDirection() async throws {
        let single = try await WheelHarness.make(
            try WheelFixtures.rtlPublication(name: "rtl-single"), double: false)
        defer { single.close() }
        XCTAssertTrue(single.view.isRTL)
        await single.advance(times: 2)
        XCTAssertEqual(single.view.pageInItem, 2, "章の途中から始める")
        let singleX = try await single.scrollX()
        XCTAssertLessThan(singleX, 0, "右綴じの横書きの章の途中では scrollX が負")
        // 右綴じ: 縦は下 = 先へ、横は左向き(dx>0)= 先へ・右向き(dx<0)= 戻る
        try await single.turn(dy: -12, expect: 3, "右綴じ単ページ 縦 下")
        try await single.turn(dy: 12, expect: 2, "右綴じ単ページ 縦 上")
        try await single.turn(dx: 12, expect: 3, "右綴じ単ページ 横 左向き")
        try await single.turn(dx: -12, expect: 2, "右綴じ単ページ 横 右向き")

        let spread = try await WheelHarness.make(
            try WheelFixtures.rtlPublication(name: "rtl-spread"), double: true)
        defer { spread.close() }
        XCTAssertEqual(spread.view.pagesPerScreen, 2)
        await spread.advance(times: 2)
        XCTAssertEqual(spread.view.pageInItem, 4, "章の途中から始める")
        let spreadX = try await spread.scrollX()
        XCTAssertLessThan(spreadX, 0, "右綴じの横書きの章の途中では scrollX が負")
        try await spread.turn(dy: -12, expect: 6, "右綴じ見開き 縦 下")
        try await spread.turn(dy: 12, expect: 4, "右綴じ見開き 縦 上")
        try await spread.turn(dx: 12, expect: 6, "右綴じ見開き 横 左向き")
        try await spread.turn(dx: -12, expect: 4, "右綴じ見開き 横 右向き")
    }

    // MARK: 当たり判定で選ばれたビューへ配る

    /// テストが WebView に直接当てるだけでは、実際の配送(窓の当たり判定)で
    /// WashiWebView に届くことまでは分からない
    func testWheelDeliveredToHitTestedViewTurnsPage() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.verticalBody(), name: "route"),
            double: true)
        defer { harness.close() }
        await harness.advance(times: 2)
        XCTAssertEqual(harness.view.pageInItem, 4, "章の途中から始める")
        let scrollX = try await harness.scrollX()
        XCTAssertLessThan(scrollX, 0, "縦書きの見開きの章の途中では scrollX が負")
        let hit = try XCTUnwrap(harness.hitView(), "WebView の中央に当たるビューがある")
        XCTAssertTrue(hit === harness.webView || hit.isDescendant(of: harness.webView),
                      "WebView の中央の当たり判定は WashiWebView(かその内側): \(hit)")
        try await harness.turn(dx: 12, expect: 6, "当たったビューへの横ホイール 左向き", to: hit)
        try await harness.turn(dy: 12, expect: 4, "当たったビューへの縦ホイール 上", to: hit)
    }

    // MARK: めくりのカバーの上

    /// めくり演出や spine 遷移の間は、カバー(NSImageView)が当たり判定を取る。
    /// macOS 27 の AppKit では、カバー(NSView の既定の scrollWheel)は位置の下にある
    /// WebView へ転送する。転送先が親(EPUBReaderView)になる場合も、WebView の上の
    /// ホイールとして送りに回り、ラッチの時刻を進めるので、カバーが畳まれた後の
    /// 慣性でもう 1 ページ送らない
    func testWheelOverTurnCoverTurnsAndKeepsLatchForMomentum() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "cover"),
            double: false)
        defer { harness.close() }
        await harness.advance(times: 2)
        XCTAssertEqual(harness.view.pageInItem, 2)
        let cover = NSImageView(frame: harness.view.bounds)
        harness.view.installTurnCover(cover, pending: false)
        defer { harness.view.foldTurnCover(cover) }
        XCTAssertTrue(harness.hitView() === cover, "カバーが当たり判定を取る")

        // 実際の配送どおり、当たったカバーに当てる(AppKit が選ぶ転送先を問わず送る)
        try await harness.turn(dy: -12, expect: 3, "カバーに当てたホイール", to: cover)

        // 親へ転送された場合の経路: WebView の枠の内側の位置で EPUBReaderView に当てる。
        // 1 ジェスチャの前半として、時刻は 16ms 刻みで付け、後半(慣性)と実時間の
        // 待ちを挟んでもひと続きにする
        let last = try await harness.gesture(
            dy: -12, to: harness.view, startingAt: ProcessInfo.processInfo.systemUptime)
        let turned = await waitUntil(timeout: .seconds(3)) { harness.view.pageInItem == 4 }
        XCTAssertTrue(turned, "WebView の上で親に届いたホイールでも送る: "
                      + "pageInItem=\(harness.view.pageInItem)")

        harness.view.foldTurnCover(cover)
        let afterFold = try XCTUnwrap(harness.hitView())
        XCTAssertTrue(afterFold === harness.webView || afterFold.isDescendant(of: harness.webView))
        // 続きの慣性(phase なし・momentum continue)を、カバーが畳まれた後の WebView に当てる
        for index in 1...12 {
            let momentum = try XCTUnwrap(harness.scrollEvent(
                dx: 0, dy: -12, phase: 0, momentumPhase: 2,
                timestamp: last + 0.016 * Double(index)))
            afterFold.scrollWheel(with: momentum)
            try await Task.sleep(for: .milliseconds(16))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(harness.view.pageInItem, 4, "カバーが畳まれた後の慣性ではもう送らない")
    }

    // MARK: WebKit へ渡す移動量 0 の複製

    /// 受けたホイールは WebKit に届かないので、WebKit が phase began で行う
    /// 辞書のポップオーバー等の片付けのため、始まりと終わりだけ移動量 0 の複製を渡す。
    /// WebKit は移動量 0 の wheel を DOM に渡さない(stopPropagation してから配る)ので、
    /// 複製が WebKit に入ったことは WashiWebView の観測点で確かめ、DOM では
    /// 移動量のある wheel が漏れていないことを確かめる
    func testConsumedGestureForwardsZeroDeltaBoundaryToWebKit() async throws {
        let harness = try await WheelHarness.make(
            try WheelFixtures.publication(body: WheelFixtures.horizontalBody(), name: "boundary"),
            double: false)
        defer { harness.close() }
        let webView = try XCTUnwrap(harness.webView as? WashiWebView)
        XCTAssertEqual(harness.view.pageInItem, 0)
        // 1 ページ先の scrollX を控えてから先頭へ戻る
        harness.view.goForward()
        _ = await waitUntil(timeout: .seconds(5)) { harness.view.pageInItem == 1 }
        let pageOneX = try await harness.scrollX()
        harness.view.goBackward()
        _ = await waitUntil(timeout: .seconds(5)) { harness.view.pageInItem == 0 }
        try await Task.sleep(for: .milliseconds(400))
        let startX = try await harness.scrollX()
        XCTAssertEqual(startX, 0, "先頭(scrollX が 0。WebKit が wheel を DOM に渡す)から始める")
        XCTAssertNotEqual(pageOneX, startX)

        try await harness.runJS("""
            globalThis.__wheels = [];
            globalThis.__scrollCount = 0;
            window.addEventListener('wheel', (event) => {
                globalThis.__wheels.push([event.deltaX, event.deltaY]);
            }, { capture: true, passive: true });
            window.addEventListener('scroll', () => { globalThis.__scrollCount += 1; },
                                    { capture: true, passive: true });
            return 0;
            """)
        var forwarded: [NSEvent] = []
        webView.didForwardGestureBoundaryForTest = { forwarded.append($0) }
        defer { webView.didForwardGestureBoundaryForTest = nil }

        // 閾値に届かない began と ended: 送らず、複製でスクロールもしない
        // (移動量が残っていれば、先頭の横書きは WebKit が右へスクロールする)
        let send = { (dx: Int32, dy: Int32, phase: Int64) throws in
            let event = try XCTUnwrap(harness.scrollEvent(dx: dx, dy: dy, phase: phase))
            harness.webView.scrollWheel(with: event)
        }
        try send(-12, 0, 1)
        try send(0, 0, 4)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(harness.view.pageInItem, 0, "閾値に届かないジェスチャでは送らない")
        let quietX = try await harness.scrollX()
        XCTAssertEqual(quietX, startX, "移動量 0 の複製ではスクロールしない")
        let quietScrolls = try await harness.runJS("return globalThis.__scrollCount;")
        XCTAssertEqual(quietScrolls, 0, "移動量 0 の複製ではスクロールしない")

        // 1 イベントで閾値を超える began と ended: ちょうど 1 ページ送る
        try send(0, -60, 1)
        try send(0, 0, 4)
        let turned = await waitUntil(timeout: .seconds(3)) { harness.view.pageInItem == 1 }
        XCTAssertTrue(turned, "began 1 つで送る")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(harness.view.pageInItem, 1, "複製で二度送らない")
        let turnedX = try await harness.scrollX()
        XCTAssertEqual(turnedX, pageOneX, "送った先から複製でずれない")

        XCTAssertEqual(forwarded.map(\.phase), [.began, .ended, .began, .ended],
                       "受けたジェスチャの始まりと終わりだけを WebKit に渡す")
        for event in forwarded {
            XCTAssertEqual(event.scrollingDeltaX, 0)
            XCTAssertEqual(event.scrollingDeltaY, 0)
            XCTAssertEqual(event.deltaX, 0)
            XCTAssertEqual(event.deltaY, 0)
            XCTAssertEqual(event.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
            XCTAssertEqual(event.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
            XCTAssertEqual(event.cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 0)
            XCTAssertEqual(event.cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), 0)
        }
        let leaked = try await harness.runJS("""
            return globalThis.__wheels.filter(([x, y]) => x !== 0 || y !== 0).length;
            """)
        XCTAssertEqual(leaked, 0, "移動量のある wheel は DOM に届かない")
    }

    /// 複製は移動量だけを 0 にし、phase・時刻を保ち、位置を元の窓座標にそろえる
    /// (WebKit なしで確かめる)
    func testZeroDeltaCopyKeepsPhaseTimeAndWindowLocation() throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 2, wheel1: -30, wheel2: 18, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        cg.location = CGPoint(x: 400, y: 300)
        cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertNotEqual(event.scrollingDeltaY, 0)

        let origin = NSPoint(x: 120, y: 80)
        let copy = try XCTUnwrap(WashiWebView.zeroDeltaCopy(of: event, windowOrigin: origin))
        XCTAssertEqual(copy.type, .scrollWheel)
        XCTAssertEqual(copy.phase, .began)
        XCTAssertEqual(copy.timestamp, event.timestamp)
        XCTAssertTrue(copy.hasPreciseScrollingDeltas)
        XCTAssertEqual(copy.scrollingDeltaX, 0)
        XCTAssertEqual(copy.scrollingDeltaY, 0)
        XCTAssertEqual(copy.deltaX, 0)
        XCTAssertEqual(copy.deltaY, 0)
        // window が nil の NSEvent の locationInWindow は画面座標。窓の原点を引いた
        // 窓座標になっている
        XCTAssertEqual(copy.locationInWindow.x, event.locationInWindow.x - origin.x, accuracy: 0.5)
        XCTAssertEqual(copy.locationInWindow.y, event.locationInWindow.y - origin.y, accuracy: 0.5)
        // 窓が無ければ位置は変えない
        let unmoved = try XCTUnwrap(WashiWebView.zeroDeltaCopy(of: event, windowOrigin: nil))
        XCTAssertEqual(unmoved.locationInWindow, event.locationInWindow)
    }

    // MARK: ページ表示の項目からスクロール表示の項目へ読み込む間

    /// 読み込みの間は effectiveFlow が先に新しい(スクロール表示の)項目を指すが、
    /// 表示されているのは古いページ表示の文書。WebKit に渡すとスクロールしてから戻される
    func testWheelWhileLoadingScrolledItemStaysOffWebKit() async throws {
        let book = try scrollPublication(flow: "paginated", modes: ["horizontal-tb", "horizontal-tb"],
                                         overrides: ["", "rendition:flow-scrolled-doc"])
        let harness = try await WheelHarness.make(
            book, double: false, at: EPUBLocator(spineIndex: 0, progression: 1))
        defer { harness.close() }
        let webView = try XCTUnwrap(harness.webView as? WashiWebView)
        XCTAssertFalse(EPUBScreenMetrics.isScrolled(harness.view.effectiveFlow))
        var forwarded: [NSEvent] = []
        webView.didForwardGestureBoundaryForTest = { forwarded.append($0) }
        defer { webView.didForwardGestureBoundaryForTest = nil }

        // 読み込みを始めた瞬間(古い文書がまだ表示されている)にホイールを当てる
        var sentDuringLoad: NSEvent?
        var flowWasScrolled = false
        var wasLoading = false
        harness.view.spineLoadHandler = { [weak webView] request in
            wasLoading = harness.view.spineLoad.isLoadingSpineItem
            flowWasScrolled = EPUBScreenMetrics.isScrolled(harness.view.effectiveFlow)
            if let event = harness.scrollEvent(dx: 0, dy: -60, phase: 1) {
                sentDuringLoad = event
                webView?.scrollWheel(with: event)
            }
            return webView?.load(request)
        }
        let movesBefore = harness.spy.moveCount
        harness.view.goForward()
        let loaded = await waitUntil(timeout: .seconds(5)) {
            harness.spy.moveCount > movesBefore && harness.view.currentSpineIndex == 1
                && !harness.view.spineLoad.isLoadingSpineItem
        }
        harness.view.spineLoadHandler = nil
        XCTAssertTrue(loaded, "スクロール表示の章が読み込まれる")
        let event = try XCTUnwrap(sentDuringLoad, "読み込みの間にホイールを当てた")
        XCTAssertTrue(wasLoading, "読み込み中に当てた")
        XCTAssertTrue(flowWasScrolled, "このとき effectiveFlow は新しいスクロール表示の項目を指す")
        // 受けた(WebKit に渡さず turnPageByWheel に回した)ことの観測: 読み込み中の
        // turnPageByWheel はラッチの時刻をそのイベントにし、WashiWebView は始まりの複製だけを渡す
        XCTAssertEqual(forwarded.map(\.timestamp), [event.timestamp],
                       "読み込み中のホイールは受けて、移動量 0 の複製だけを WebKit に渡す")
        XCTAssertGreaterThanOrEqual(harness.view.wheelTurnLatch.lastTime, event.timestamp)
        XCTAssertEqual(harness.view.currentSpineIndex, 1, "読み込み中のホイールでは送らない")

        // 読み込みが終われば、スクロール表示のホイールは従来どおり WebKit がスクロールする
        try await Task.sleep(for: .milliseconds(600))
        forwarded.removeAll()
        let before = try await harness.scrollY()
        try await harness.gesture(dy: -12)
        try await Task.sleep(for: .milliseconds(600))
        let after = try await harness.scrollY()
        XCTAssertGreaterThan(after, before, "読み込み後のスクロール表示は WebKit がスクロールする")
        XCTAssertTrue(forwarded.isEmpty, "スクロール表示のホイールは受けずにそのまま渡す")
    }

    // MARK: 章をまたいだフリックの慣性(行き先がスクロール表示)

    /// 最後のページからのフリックでスクロール表示の章へ読み込むと、読み込み(0.1〜0.3 秒)の
    /// 後も慣性(約 1 秒)が続く。その残りで、現れたばかりの章を先頭から動かさない。
    /// 0.25 秒静かになってからの新しいジェスチャはスクロールする。
    /// 時刻は 16ms 刻みで付け、実時間の揺れ(読み込み・JS の往復)から切り離す
    func testMomentumSpanningLoadIntoScrolledChapterDoesNotScrollIt() async throws {
        let book = try scrollPublication(flow: "paginated", modes: ["horizontal-tb", "horizontal-tb"],
                                         overrides: ["", "rendition:flow-scrolled-doc"])
        let harness = try await WheelHarness.make(
            book, double: false, at: EPUBLocator(spineIndex: 0, progression: 1))
        defer { harness.close() }
        XCTAssertFalse(EPUBScreenMetrics.isScrolled(harness.view.effectiveFlow))
        var time = ProcessInfo.processInfo.systemUptime
        var sentWhileLoading = 0
        let send = { (dy: Int32, phase: Int64, momentum: Int64) throws in
            if harness.view.spineLoad.isLoadingSpineItem { sentWhileLoading += 1 }
            time += 0.016
            let event = try XCTUnwrap(harness.scrollEvent(
                dx: 0, dy: dy, phase: phase, momentumPhase: momentum, timestamp: time))
            harness.webView.scrollWheel(with: event)
        }
        let movesBefore = harness.spy.moveCount
        let loaded = {
            harness.spy.moveCount > movesBefore && harness.view.currentSpineIndex == 1
                && !harness.view.spineLoad.isLoadingSpineItem
        }
        // 読み込みはこの環境では 16ms より短く終わりうるので、読み込みを始めた瞬間にも
        // 慣性を 1 つ当てる(読み込みをまたぐことを確実にする)
        harness.view.spineLoadHandler = { [weak webView = harness.webView] request in
            try? send(-12, 0, 2)
            return webView?.load(request)
        }
        defer { harness.view.spineLoadHandler = nil }
        // フリック: began → changed(5 イベント目で章の最後から送る)→ ended
        try send(-12, 1, 0)
        for _ in 0..<5 { try send(-12, 2, 0) }
        try send(0, 4, 0)
        // 慣性(momentum begin → continue)を読み込みが終わるまで 16ms ごとに続ける
        try send(-12, 0, 1)
        for _ in 0..<300 where !loaded() {
            try await Task.sleep(for: .milliseconds(16))
            try send(-12, 0, 2)
        }
        XCTAssertTrue(loaded(), "スクロール表示の章が読み込まれる")
        XCTAssertGreaterThan(sentWhileLoading, 0, "慣性が読み込みをまたぐ")
        XCTAssertTrue(EPUBScreenMetrics.isScrolled(harness.view.effectiveFlow))
        let start = try await harness.scrollY()
        XCTAssertEqual(start, 0, "章の先頭から表示する")

        // 読み込み後も続く慣性(直前のイベントから 16ms 刻み = 0.25 秒以内)
        for _ in 0..<15 {
            try send(-12, 0, 2)
            try await Task.sleep(for: .milliseconds(16))
        }
        try send(0, 0, 3)
        try await Task.sleep(for: .milliseconds(400))
        let afterTail = try await harness.scrollY()
        XCTAssertEqual(afterTail, start, "読み込みの前から続く慣性では新しい章を動かさない")
        XCTAssertEqual(harness.view.currentSpineIndex, 1)

        // 0.3 秒以上静かになってからの新しいジェスチャ(今の時刻)はスクロールする
        try await Task.sleep(for: .milliseconds(300))
        try await harness.gesture(dy: -12)
        try await Task.sleep(for: .milliseconds(600))
        let afterFresh = try await harness.scrollY()
        XCTAssertGreaterThan(afterFresh, start, "静かになってからの新しいジェスチャはスクロールする")
        XCTAssertFalse(harness.view.wheelTurnLatch.holdsLoadGesture, "保持は新しいジェスチャで解ける")
    }

    /// 読み込みの前から続くジェスチャの保持は、新しいジェスチャの始まり・0.25 秒の静穏・
    /// ラッチの解除で解け、解けたら次の読み込みまで戻らない(WebKit なしで確かめる)
    func testLoadGestureHoldEndsOnNewGestureOrQuiet() throws {
        func event(phase: Int64, momentum: Int64 = 0, at time: TimeInterval) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 2, wheel1: -12, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.timestamp = UInt64(time * 1e9)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        func held(at time: TimeInterval) -> EPUBReaderView.WheelTurnLatch {
            var latch = EPUBReaderView.WheelTurnLatch()
            latch.latched = true
            latch.lastTime = time
            latch.holdsLoadGesture = true
            return latch
        }
        let t: TimeInterval = 1000

        var latch = held(at: t)
        XCTAssertTrue(latch.continuesLoadGesture(try event(phase: 2, at: t + 0.1)), "changed は続き")
        XCTAssertTrue(latch.continuesLoadGesture(try event(phase: 0, momentum: 2, at: t + 0.2)),
                      "慣性は続き")
        // 128 = mayBegin
        for (phase, label) in [(Int64(1), "began"), (Int64(128), "mayBegin")] {
            latch = held(at: t)
            XCTAssertFalse(latch.continuesLoadGesture(try event(phase: phase, at: t + 0.1)), label)
            XCTAssertFalse(latch.holdsLoadGesture, "\(label) で保持を解く")
            XCTAssertFalse(latch.continuesLoadGesture(try event(phase: 2, at: t + 0.12)),
                           "\(label) の後は戻らない")
        }
        latch = held(at: t)
        XCTAssertFalse(latch.continuesLoadGesture(try event(phase: 0, momentum: 2, at: t + 0.26)),
                       "0.25 秒の静穏で解く")
        XCTAssertFalse(latch.holdsLoadGesture)
        latch = held(at: t)
        latch.latched = false
        XCTAssertFalse(latch.continuesLoadGesture(try event(phase: 2, at: t + 0.1)),
                       "ラッチが解けていれば保持しない")
    }
}
