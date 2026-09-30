import AppKit
import CoreGraphics
import WebKit
import XCTest
@testable import Washi

/// ホイール/トラックパッドの「1 ジェスチャ = 1 ページ」送り。
/// 縦書きの見開きで章の途中(scrollX が負)にいると、WebKit は wheel を DOM に
/// 渡さず自前でスクロールするため、JS の wheel 処理では送れなかった。
/// 本物の scrollWheel を WashiWebView に当てて確かめる。
@MainActor
final class WheelPageTurnTests: XCTestCase {
    private struct Harness {
        let view: EPUBReaderView
        let webView: WKWebView
        let window: NSWindow
        let spy: ReaderObservationSpy
    }

    private var harnesses: [Harness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            closeReader(harness.view, in: harness.window,
                        teardown: .cancelPageCensus, clearsDelegate: true)
        }
        harnesses = []
        try await super.tearDown()
    }

    private func verticalBody() -> String {
        "<style>html{writing-mode:vertical-rl;-epub-writing-mode:vertical-rl}</style>"
            + (1...120).map { "<p>行\($0) 縦書きの本文。ホイールでページを送る。</p>" }.joined()
    }

    private func horizontalBody() -> String {
        (1...120).map { "<p>Line \($0) horizontal text for wheel page turns.</p>" }.joined()
    }

    private func publication(body: String, name: String) throws -> EPUBPublication {
        try EPUBFixtures.publication(
            EPUBFixtures.singleSpineEntries(bodyHTML: body), name: "washi-wheel-\(name)")
    }

    /// 窓はスクリーン原点に置く。CGEvent から作る NSEvent は window が nil で、
    /// locationInWindow がスクリーン座標になるため(スクロール表示で WebKit に渡す
    /// テストで、窓座標と一致させる必要がある)。
    private func makeReader(_ publication: EPUBPublication, double: Bool,
                            at locator: EPUBLocator? = nil,
                            configure: (inout EPUBReaderSettings) -> Void = { _ in })
    async throws -> Harness {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 752, height: 508))
        var settings = view.settings
        settings.columnMode = double ? .double : .single
        settings.pageTurnStyle = .none
        configure(&settings)
        view.settings = settings
        let spy = ReaderObservationSpy()
        view.delegate = spy
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.load(publication: publication, at: locator)
        guard await waitUntil(timeout: .seconds(5), { spy.moveCount > 0 }) else {
            closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true)
            try failOrSkipIfWebKitUnavailable()
            throw XCTSkip("unreachable")
        }
        // 読み込み直後の 0.25 秒は送らない(慣性の持ち越し防止)ので、それを抜けてから当てる
        try await Task.sleep(for: .milliseconds(600))
        let webView = try view.firstWebView()
        let harness = Harness(view: view, webView: webView, window: window, spy: spy)
        harnesses.append(harness)
        return harness
    }

    private func scrollEvent(dx: Int32, dy: Int32, phase: Int64,
                             in webView: WKWebView) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return nil }
        // kCGScrollWheelEventIsContinuous(88)=1・kCGScrollWheelEventScrollPhase(99):
        // トラックパッドや横ホイール付きマウスと同じ「精密・phase 付き」の形にする
        cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
        cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
        let frame = webView.convert(webView.bounds, to: nil)
        let screenHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        cg.location = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
        // 時刻を必ず入れる。CGEvent は既定で timestamp が 0 になり、送りの処理の
        // 「0.25 秒の静穏で区切る」判定が一度も効かない(調査中に実際に踏んだ)
        cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return NSEvent(cgEvent: cg)
    }

    /// 1 ジェスチャ: began(1) → changed(2) を `changes` 回 → ended(4)。
    /// dx/dy は AppKit の scrollingDelta の符号(負 = 文書の先へ)。
    private func gesture(_ harness: Harness, dx: Int32 = 0, dy: Int32 = 0,
                         changes: Int = 10, interval: Duration = .milliseconds(16)) async throws {
        let phases: [Int64] = [1] + Array(repeating: 2, count: changes) + [4]
        for phase in phases {
            let event = try XCTUnwrap(scrollEvent(
                dx: phase == 4 ? 0 : dx, dy: phase == 4 ? 0 : dy,
                phase: phase, in: harness.webView))
            harness.webView.scrollWheel(with: event)
            try await Task.sleep(for: interval)
        }
    }

    /// ジェスチャを当て、ページが `expected` になるのを待つ。次のジェスチャが
    /// 別のジェスチャとして数えられるよう、0.25 秒より長く手を止めてから戻る
    private func turn(_ harness: Harness, dx: Int32 = 0, dy: Int32 = 0,
                      expect expected: Int, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        try await gesture(harness, dx: dx, dy: dy)
        let landed = await waitUntil(timeout: .seconds(3)) { harness.view.pageInItem == expected }
        XCTAssertTrue(landed, "\(message): pageInItem=\(harness.view.pageInItem) 期待 \(expected)",
                      file: file, line: line)
        try await Task.sleep(for: .milliseconds(400))
    }

    private func advance(_ harness: Harness, times: Int) async {
        for _ in 0..<times {
            let before = harness.view.pageInItem
            harness.view.goForward()
            _ = await waitUntil(timeout: .seconds(5)) { harness.view.pageInItem != before }
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: テスト 1 — 縦書き見開き・章の途中(修正前は失敗する)

    func testVerticalSpreadMidChapterTurnsWithHorizontalAndVerticalWheel() async throws {
        let harness = try await makeReader(
            try publication(body: verticalBody(), name: "vrl-spread"), double: true)
        XCTAssertEqual(harness.view.pagesPerScreen, 2)
        await advance(harness, times: 2)
        XCTAssertEqual(harness.view.pageInItem, 4, "章の途中(scrollX が負)から始める")

        // 縦書き(右綴じ): 左向き(dx>0)= 先へ、右向き(dx<0)= 戻る
        try await turn(harness, dx: 12, expect: 6, "横ホイール 左向き")
        try await turn(harness, dx: -12, expect: 4, "横ホイール 右向き")
        try await turn(harness, dy: -12, expect: 6, "縦ホイール 下")
        try await turn(harness, dy: 12, expect: 4, "縦ホイール 上")
    }

    // MARK: テスト 2 — 今まで正常だった条件の回帰

    func testOtherLayoutsKeepOneGesturePerPage() async throws {
        let htbSpread = try await makeReader(
            try publication(body: horizontalBody(), name: "htb-spread"), double: true)
        await advance(htbSpread, times: 2)
        XCTAssertEqual(htbSpread.view.pageInItem, 4)
        // 横書き(左綴じ): 右向き(dx<0)= 先へ
        try await turn(htbSpread, dx: -12, expect: 6, "横書き見開き 横 右向き")
        try await turn(htbSpread, dx: 12, expect: 4, "横書き見開き 横 左向き")
        try await turn(htbSpread, dy: -12, expect: 6, "横書き見開き 縦 下")

        let vrlSingle = try await makeReader(
            try publication(body: verticalBody(), name: "vrl-single"), double: false)
        await advance(vrlSingle, times: 2)
        XCTAssertEqual(vrlSingle.view.pageInItem, 2)
        try await turn(vrlSingle, dx: 12, expect: 3, "縦書き単ページ 横 左向き")
        try await turn(vrlSingle, dx: -12, expect: 2, "縦書き単ページ 横 右向き")
        try await turn(vrlSingle, dy: -12, expect: 3, "縦書き単ページ 縦 下")

        let htbSingle = try await makeReader(
            try publication(body: horizontalBody(), name: "htb-single"), double: false)
        await advance(htbSingle, times: 2)
        XCTAssertEqual(htbSingle.view.pageInItem, 2)
        try await turn(htbSingle, dx: -12, expect: 3, "横書き単ページ 横 右向き")
        try await turn(htbSingle, dy: 12, expect: 2, "横書き単ページ 縦 上")
    }

    // MARK: テスト 3 — 横方向の 2 設定

    func testHorizontalWheelSettingsGateAndReverse() async throws {
        let gated = try await makeReader(
            try publication(body: horizontalBody(), name: "gated"), double: false) {
            $0.horizontalWheelTurnsPages = false
        }
        await advance(gated, times: 2)
        let start = gated.view.pageInItem
        try await gesture(gated, dx: -12)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(gated.view.pageInItem, start, "横方向の送りが OFF なら横ホイールでは送らない")
        try await turn(gated, dy: -12, expect: start + 1, "OFF でも縦ホイールでは送る")

        let reversed = try await makeReader(
            try publication(body: horizontalBody(), name: "reversed"), double: false) {
            $0.reversesHorizontalWheelTurn = true
        }
        await advance(reversed, times: 2)
        XCTAssertEqual(reversed.view.pageInItem, 2)
        try await turn(reversed, dx: -12, expect: 1, "反転: 右向きで戻る")
    }

    // MARK: テスト 4 — スクロール表示は WebKit に任せる

    func testScrolledFlowLeavesWheelToWebKit() async throws {
        let harness = try await makeReader(
            try scrollPublication(flow: "scrolled-doc"), double: false)
        let before = try await scrollY(harness.webView)
        try await gesture(harness, dy: -12)
        try await Task.sleep(for: .milliseconds(600))
        let after = try await scrollY(harness.webView)
        XCTAssertGreaterThan(after, before, "スクロール表示では WebKit がスクロールする")
    }

    private func scrollY(_ webView: WKWebView) async throws -> Double {
        try await Task(priority: .userInitiated) { @MainActor in
            let raw = try await webView.callAsyncJavaScript(
                "return window.scrollY;", in: nil, contentWorld: WashiContentWorld.world)
            return (raw as? Double) ?? Double((raw as? Int) ?? -1)
        }.value
    }

    // MARK: テスト 5 — 章をまたいだ直後の慣性で余分に送らない

    private func twoChapterPublication() throws -> EPUBPublication {
        try scrollPublication(flow: "paginated", modes: ["horizontal-tb", "horizontal-tb"])
    }

    /// 5a: 章の最後から送ったジェスチャの続き(慣性)で、次の章をもう 1 ページ送らない
    func testMomentumAfterCrossingChapterDoesNotTurnAgain() async throws {
        let harness = try await makeReader(
            try twoChapterPublication(), double: false,
            at: EPUBLocator(spineIndex: 0, progression: 1))
        XCTAssertEqual(harness.view.currentSpineIndex, 0)
        // 約 0.5 秒続く 1 ジェスチャ(最初の数イベントで閾値を超え、残りは慣性相当)
        try await gesture(harness, dy: -12, changes: 30)
        let crossed = await waitUntil(timeout: .seconds(3)) { harness.view.currentSpineIndex == 1 }
        XCTAssertTrue(crossed, "次の章へ送られる")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.view.currentSpineIndex, 1)
        XCTAssertEqual(harness.view.pageInItem, 0, "慣性で次の章をさらに送らない")
    }

    /// 5b: ホイール以外(キー等)で章をまたいだ直後に続くホイールでは送らず、
    /// 0.25 秒静かになってからのジェスチャで送る
    func testWheelRightAfterChapterLoadIsIgnoredUntilQuiet() async throws {
        let harness = try await makeReader(
            try twoChapterPublication(), double: false,
            at: EPUBLocator(spineIndex: 0, progression: 1))
        harness.view.goForward()
        try await gesture(harness, dy: -12, changes: 12)
        _ = await waitUntil(timeout: .seconds(3)) { harness.view.currentSpineIndex == 1 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.view.currentSpineIndex, 1)
        XCTAssertEqual(harness.view.pageInItem, 0, "読み込みの直後に続くホイールでは送らない")
        try await turn(harness, dy: -12, expect: 1, "静かになってからのジェスチャでは送る")
    }
}
