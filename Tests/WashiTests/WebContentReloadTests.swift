import AppKit
import WebKit
import XCTest
@testable import Washi

// WebContent プロセスの終了後の再読み込みの回数制限と延期(cooViewer-oxr.47)。
// delegate の観測には ReaderViewTestSupport の ReaderViewDelegateSpy を使う

@MainActor
final class WebContentReloadTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBFixtures.verticalNovel(name: "washi-reader-regression")
    }

    /// cooViewer-oxr.47: 三回の再試行は 0/250ms/1s と増加し、同じ 60 秒窓の
    /// 四回目以降は一度だけ失敗通知を要求する。
    func testWebContentReloadLimiterCapsAndBacksOff() {
        var limiter = WebContentReloadLimiter()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .reload(after: .zero))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .reload(after: .milliseconds(250)))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .reload(after: .seconds(1)))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .suppress(reportFailure: true))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .suppress(reportFailure: false))
        XCTAssertEqual(
            limiter.register(spineIndex: 2, at: now.addingTimeInterval(61)),
            .reload(after: .zero))
    }

    /// cooViewer-oxr.47: windowless 中の終了は reload せず同じ要求を延期し、
    /// 短時間四回目で打ち切って delegate へ一度だけ失敗を返す。
    func testWebContentTerminationDefersWhenWindowlessAndCapsReloads() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        view.load(publication: try makePublication())
        let webView = try view.firstWebView()

        for _ in 0..<4 {
            view.webViewWebContentProcessDidTerminate(webView)
        }

        XCTAssertEqual(view.webContentReload.requestCount, 3)
        XCTAssertEqual(view.webContentReload.attemptCount, 0)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(String(describing: delegate.failures[0]).contains(
            "web content process terminated repeatedly"))
    }

    /// cooViewer-oxr.47: windowless で受理した一回の終了は、attach 時に新しい
    /// termination として数え直さず一度だけ reload する。
    func testDeferredWebContentReloadRunsOnceAfterAttach() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.load(publication: try makePublication())
        let webView = try view.firstWebView()
        view.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(view.webContentReload.attemptCount, 0)

        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        XCTAssertEqual(view.webContentReload.requestCount, 1)
        XCTAssertEqual(view.webContentReload.attemptCount, 1)
    }

    /// cooViewer-oxr.47: spine A で予約したバックオフ reload は、B へ
    /// 移動した後に発火して現在文書を再構築しない。
    func testSpineNavigationCancelsDelayedWebContentReload() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        let publication = try makePublication()
        view.load(publication: publication)
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        view.handleWebContentProcessTermination(at: now)
        view.handleWebContentProcessTermination(at: now)
        XCTAssertTrue(view.hasPendingWebContentReload)

        view.goToBookEnd()

        XCTAssertEqual(view.currentSpineIndex,
                       publication.readingOrder.count - 1)
        XCTAssertFalse(view.hasPendingWebContentReload)
    }

    /// cooViewer-oxr.47: 再構築前の WebView からの遅配終了通知は、現在の
    /// spine の再試行回数へ数えない。
    func testStaleWebContentTerminationDoesNotConsumeReloadBudget() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.load(publication: try makePublication())
        let stale = WKWebView(frame: .zero)

        view.webViewWebContentProcessDidTerminate(stale)

        XCTAssertEqual(view.webContentReload.requestCount, 0)
        XCTAssertEqual(view.webContentReload.attemptCount, 0)
    }
}
