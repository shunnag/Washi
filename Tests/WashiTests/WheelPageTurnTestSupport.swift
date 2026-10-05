import AppKit
import CoreGraphics
import WebKit
import XCTest
@testable import Washi

// ホイールの送りのテスト(WheelPageTurnTests・WheelPageTurnRouteTests)の道具立て。
// 本物の scrollWheel を WashiWebView(または当たり判定で選ばれたビュー)に当てる。

/// ホイールのテスト用の本文と EPUB
enum WheelFixtures {
    static func verticalBody() -> String {
        "<style>html{writing-mode:vertical-rl;-epub-writing-mode:vertical-rl}</style>"
            + (1...120).map { "<p>行\($0) 縦書きの本文。ホイールでページを送る。</p>" }.joined()
    }

    static func horizontalBody() -> String {
        (1...120).map { "<p>Line \($0) horizontal text for wheel page turns.</p>" }.joined()
    }

    static func publication(body: String, name: String) throws -> EPUBPublication {
        try EPUBFixtures.publication(
            EPUBFixtures.singleSpineEntries(bodyHTML: body), name: "washi-wheel-\(name)")
    }

    /// 右綴じの横書き(dir=rtl・page-progression-direction=rtl)。章の途中では
    /// scrollX が負になる(縦書きの見開きと同じく、WebKit が wheel を DOM に渡さない)
    static func rtlPublication(name: String) throws -> EPUBPublication {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: (1...120).map {
            "<p>שורה \($0) טקסט מימין לשמאל להפיכת דפים בגלגלת.</p>"
        }.joined())
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: "<spine>", with: "<spine page-progression-direction=\"rtl\">")
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/text/c.xhtml",
            of: "xml:lang=\"ja\">", with: "xml:lang=\"he\" dir=\"rtl\">")
        return try EPUBFixtures.publication(entries, name: "washi-wheel-\(name)")
    }

    static func twoChapterPublication() throws -> EPUBPublication {
        try scrollPublication(flow: "paginated", modes: ["horizontal-tb", "horizontal-tb"])
    }
}

/// リーダー 1 つと、それにホイールを当てる道具
@MainActor
struct WheelHarness {
    let view: EPUBReaderView
    let webView: WKWebView
    let window: NSWindow
    let spy: ReaderObservationSpy

    /// 窓はスクリーン原点に置く。CGEvent から作る NSEvent は window が nil で、
    /// locationInWindow がスクリーン座標になるため(スクロール表示で WebKit に渡す
    /// テストで、窓座標と一致させる必要がある)。
    static func make(_ publication: EPUBPublication, double: Bool,
                     at locator: EPUBLocator? = nil,
                     configure: (inout EPUBReaderSettings) -> Void = { _ in })
    async throws -> WheelHarness {
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
        return WheelHarness(view: view, webView: webView, window: window, spy: spy)
    }

    /// 上流のテストと同じく、各テストで作った直後に defer で片付ける(古い Swift は
    /// MainActor の XCTestCase で非同期の tearDown から super を呼ぶことを許さない)
    func close() {
        closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true)
    }

    /// WebView の中央の、窓(= 画面原点の窓なので contentView の親)座標
    var webViewCenter: NSPoint {
        let frame = webView.convert(webView.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// 実際の配送と同じく、WebView の中央で当たり判定を取ったビュー
    func hitView() -> NSView? {
        window.contentView?.hitTest(webViewCenter)
    }

    /// `timestamp` を渡すとその時刻のイベントにする(0.25 秒の静穏の判定を実時間の
    /// 揺れから切り離すため)。渡さなければ今の時刻
    func scrollEvent(dx: Int32, dy: Int32, phase: Int64, momentumPhase: Int64 = 0,
                     timestamp: TimeInterval? = nil,
                     file: StaticString = #filePath, line: UInt = #line) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return nil }
        // 連続(精密)・phase 付き: トラックパッドや横ホイール付きマウスと同じ形にする
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        let center = webViewCenter
        let screenHeight = NSScreen.screens.first?.frame.height ?? center.y
        cg.location = CGPoint(x: center.x, y: screenHeight - center.y)
        // 時刻を必ず入れる。CGEvent は既定で timestamp が 0 になり、送りの処理の
        // 「0.25 秒の静穏で区切る」判定が一度も効かない(調査中に実際に踏んだ)
        cg.timestamp = timestamp.map { UInt64($0 * 1e9) }
            ?? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        if let timestamp {
            XCTAssertEqual(event.timestamp, timestamp, accuracy: 1e-6,
                           "合成イベントの時刻が指定と違う", file: file, line: line)
        } else {
            // NSEvent.timestamp は systemUptime と同じ時計のはず。機種(Apple Silicon 等)で
            // 時計の単位がずれると 0.25 秒の判定が壊れるので、ここで理由つきで落とす
            let skew = abs(event.timestamp - ProcessInfo.processInfo.systemUptime)
            if skew > 1 {
                XCTFail("合成イベントの時刻が systemUptime とずれている(\(skew) 秒)",
                        file: file, line: line)
            }
        }
        // 1 イベントの移動量がそのまま scrollingDelta になることに、ジェスチャの長さ
        // (送った後の残りが閾値 50 に届かない)が依存している
        XCTAssertTrue(event.hasPreciseScrollingDeltas, file: file, line: line)
        XCTAssertEqual(event.scrollingDeltaX, CGFloat(dx), file: file, line: line)
        XCTAssertEqual(event.scrollingDeltaY, CGFloat(dy), file: file, line: line)
        return event
    }

    /// 1 ジェスチャ: began(1) → changed(2) を `changes` 回 → ended(4)。
    /// dx/dy は AppKit の scrollingDelta の符号(負 = 文書の先へ)。
    /// 既定の長さ(移動量のあるイベントは began と changed 5 回の 6 つ)なら、12 px ずつで
    /// 5 イベント目に閾値 50 を超えて送り、残りは 12 px で閾値に届かない(送った後に
    /// MainActor が 0.25 秒止まってラッチが外れても、もう 1 ページ送らない)。
    /// `to` は配る先(既定は WebView)。`startingAt` を渡すと 16ms 刻みの時刻を付ける。
    /// 最後のイベントの時刻を返す
    @discardableResult
    func gesture(dx: Int32 = 0, dy: Int32 = 0, changes: Int = 5,
                 interval: Duration = .milliseconds(16), to target: NSView? = nil,
                 startingAt start: TimeInterval? = nil,
                 file: StaticString = #filePath, line: UInt = #line) async throws -> TimeInterval {
        let phases: [Int64] = [1] + Array(repeating: 2, count: changes) + [4]
        var last: TimeInterval = 0
        for (index, phase) in phases.enumerated() {
            let event = try XCTUnwrap(scrollEvent(
                dx: phase == 4 ? 0 : dx, dy: phase == 4 ? 0 : dy, phase: phase,
                timestamp: start.map { $0 + 0.016 * Double(index) }, file: file, line: line),
                file: file, line: line)
            (target ?? webView).scrollWheel(with: event)
            last = event.timestamp
            try await Task.sleep(for: interval)
        }
        return last
    }

    /// ジェスチャを当て、ページが `expected` になるのを待つ。次のジェスチャが
    /// 別のジェスチャとして数えられるよう、0.25 秒より長く手を止めてから戻る。
    /// 止めた後にもう一度確かめ、二重送りをこのジェスチャのせいとして報告する
    func turn(dx: Int32 = 0, dy: Int32 = 0, expect expected: Int, _ message: String,
              to target: NSView? = nil,
              file: StaticString = #filePath, line: UInt = #line) async throws {
        try await gesture(dx: dx, dy: dy, to: target, file: file, line: line)
        let landed = await waitUntil(timeout: .seconds(3)) { view.pageInItem == expected }
        XCTAssertTrue(landed, "\(message): pageInItem=\(view.pageInItem) 期待 \(expected)",
                      file: file, line: line)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(view.pageInItem, expected, "\(message): 1 ジェスチャで 2 ページ以上送った",
                       file: file, line: line)
    }

    func advance(times: Int) async {
        for _ in 0..<times {
            let before = view.pageInItem
            view.goForward()
            _ = await waitUntil(timeout: .seconds(5)) { view.pageInItem != before }
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    @discardableResult
    func runJS(_ body: String) async throws -> Double {
        let webView = webView
        return try await Task(priority: .userInitiated) { @MainActor in
            let raw = try await webView.callAsyncJavaScript(
                body, in: nil, contentWorld: WashiContentWorld.world)
            return (raw as? Double) ?? Double((raw as? Int) ?? -1)
        }.value
    }

    func scrollX() async throws -> Double { try await runJS("return window.scrollX;") }
    func scrollY() async throws -> Double { try await runJS("return window.scrollY;") }
}
