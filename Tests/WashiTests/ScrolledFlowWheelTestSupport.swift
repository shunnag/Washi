import AppKit
import CoreGraphics
import WebKit
import XCTest
@testable import Washi

@MainActor
final class ScrolledFlowWheelHarness {
    let reader = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let spy = ReaderObservationSpy()
    let window: NSWindow
    private(set) var consumedEvents: [Bool] = []

    init() {
        reader.settings.insets = .zero
        reader.settings.columnMode = .double
        reader.settings.pageTurnStyle = .none
        // ページ送りを無効にしてもスクロールが働くことを全ケースで検証する。
        reader.settings.wheelTurnsPages = false
        reader.settings.horizontalWheelTurnsPages = false
        reader.settings.reversesHorizontalWheelTurn = true
        window = makeOffscreenWindow(containing: reader, ignoresMouseEvents: false)
        // CGEvent 由来の NSEvent は window が nil なので、窓座標と画面座標を揃える。
        window.setFrameOrigin(.zero)
        reader.delegate = spy
    }

    func close() {
        closeReader(reader, in: window, teardown: .unload, clearsDelegate: true)
    }

    func load(_ book: EPUBPublication, at locator: EPUBLocator? = nil) async throws {
        let moves = spy.moveCount
        reader.load(publication: book, at: locator)
        reader.layoutSubtreeIfNeeded()
        guard await waitUntil(timeout: .seconds(8), {
            self.spy.moveCount > moves || !self.spy.failures.isEmpty
        }) else {
            try failOrSkipIfWebKitUnavailable()
            throw NSError(domain: "ScrolledFlowWheelTests", code: 1)
        }
        XCTAssertTrue(spy.failures.isEmpty, spy.failures.description)
        // 実際の文書・setup の失敗を「WebKit 不在」の skip へ置き換えない。
        guard spy.failures.isEmpty else { throw NSError(domain: "ScrolledFlowWheelTests", code: 2) }
        let webView = try XCTUnwrap(try reader.firstWebView() as? WashiWebView)
        let ready = await waitUntil(timeout: .seconds(8)) {
            !self.reader.spineLoad.isLoadingSpineItem && !self.reader.spineLoad.isSettingUp
                && webView.alphaValue == 1
        }
        XCTAssertTrue(ready, "初回レイアウトが確定しない")
        // 再ページ割りの Task は完了後も保持される。nil 判定ではなく完了を待つ。
        if let pagination = reader.repagination.repaginateWork { await pagination.value }
        consumedEvents.removeAll()
        let handler = webView.wheelHandler
        webView.wheelHandler = { [weak self] event in
            let consumed = handler?(event) ?? false
            self?.consumedEvents.append(consumed)
            return consumed
        }
        _ = try await reader.evaluateForTest("""
            globalThis.__domWheelCount = 0;
            globalThis.__nativeWheelCalls = 0;
            const countWheel = () => { globalThis.__domWheelCount += 1; };
            document.addEventListener('wheel', countWheel, { capture:true, passive:true });
            for (const frame of document.querySelectorAll('iframe')) {
                frame.contentDocument.addEventListener('wheel', countWheel, { capture:true, passive:true });
            }
            const scroll = __washi.scrollByWheelDelta;
            __washi.scrollByWheelDelta = (...args) => {
                globalThis.__nativeWheelCalls += 1;
                return scroll(...args);
            };
            return true;
            """)
        let initial = try await metrics()
        XCTAssertEqual(initial["ready"] as? Bool, true)
    }

    func metrics() async throws -> [String: Any] {
        let value = try await reader.evaluateForTest("""
            return { ...__washi.scrollMetrics(), scrollX:window.scrollX,
                     domWheels:globalThis.__domWheelCount, nativeCalls:globalThis.__nativeWheelCalls,
                     children:Array.from(document.querySelectorAll('iframe'), frame => ({
                         ...frame.contentWindow.__washi.scrollMetrics(), scrollX:frame.contentWindow.scrollX
                     })) };
            """)
        return try XCTUnwrap(value as? [String: Any])
    }

    func offset() async throws -> Double {
        let value = try await metrics()
        return try XCTUnwrap(value["offset"] as? Double)
    }

    func drain(file: StaticString = #filePath, line: UInt = #line) async {
        let finished = await waitUntil(timeout: .seconds(3)) {
            let state = self.reader.scrolledWheel
            return !state.isScheduled && !state.isInFlight && state.pendingDeltas.isEmpty
        }
        XCTAssertTrue(finished, "ホイールの JS 送信が完了しない", file: file, line: line)
    }

    func send(dx: Int32 = 0, dy: Int32 = 0, precise: Bool = true,
              phase: Int64 = 2, momentum: Int64 = 0) throws {
        let webView = try reader.firstWebView()
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let frame = webView.convert(webView.bounds, to: nil)
        let screenHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        event.location = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let scroll = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertEqual(scroll.hasPreciseScrollingDeltas, precise)
        XCTAssertLessThan(abs(scroll.timestamp - ProcessInfo.processInfo.systemUptime), 1)
        webView.scrollWheel(with: scroll)
    }

    /// 既存の WheelPageTurnTests と同じ began → changed × 10 → ended の 132px。
    func gesture(dx: Int32 = 0, dy: Int32 = 0) async throws {
        let phases: [Int64] = [1] + Array(repeating: 2, count: 10) + [4]
        for phase in phases {
            try send(dx: phase == 4 ? 0 : dx, dy: phase == 4 ? 0 : dy, phase: phase)
            try await Task.sleep(for: .milliseconds(16))
        }
        await drain()
    }

    func waitForMovement(from initial: Double, file: StaticString = #filePath,
                         line: UInt = #line) async throws -> Double {
        let deadline = ContinuousClock.now + .seconds(3)
        var position = try await offset()
        while abs(position - initial) < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            position = try await offset()
        }
        XCTAssertGreaterThan(abs(position - initial), 1, "WebKit がスクロールしない", file: file, line: line)
        return position
    }
}
