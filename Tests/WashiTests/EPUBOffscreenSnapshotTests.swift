import WebKit
import XCTest
@testable import Washi

@MainActor
final class EPUBOffscreenSnapshotTests: XCTestCase {
    /// WebKit が応答しなくても、取消後は後続の描画へ進める。
    func testCancellationDoesNotWaitForWebKitCallback() async throws {
        try await assertStopsWithoutCallback(cancel: true)
    }

    /// タイムアウトの後から応答しても、待機を二重に再開しない。
    func testTimeoutDoesNotWaitForWebKitCallback() async throws {
        try await assertStopsWithoutCallback(cancel: false)
    }

    private func assertStopsWithoutCallback(cancel: Bool) async throws {
        let started = expectation(description: "スナップショット開始")
        let finished = expectation(description: "WebKit の応答前に待機を終了")
        let view = SnapshotProbeWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.started = started
        var result: Result<CGImage, any Error>?
        let task = Task { @MainActor in
            do {
                result = .success(try await takeOffscreenSnapshot(
                    webView: view, configuration: WKSnapshotConfiguration(),
                    timeout: cancel ? .seconds(5) : .milliseconds(20)))
            } catch {
                result = .failure(error)
            }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        if cancel { task.cancel() }
        await fulfillment(of: [finished], timeout: 1)
        // 修正前もテストタスクを残さず、修正後は遅れてきた応答を検証する。
        view.completeWithError()
        await task.value
        guard case .failure(let error) = result else {
            return XCTFail("応答しないスナップショットが成功した")
        }
        if cancel {
            XCTAssertTrue(error is CancellationError)
        } else {
            XCTAssertEqual(error as? EPUBPageRasterizer.RasterizeError, .snapshotFailed)
        }
    }
}

@MainActor
private final class SnapshotProbeWebView: WKWebView {
    var started: XCTestExpectation?
    private var completion: (@MainActor (NSImage?, (any Error)?) -> Void)?

    override func takeSnapshot(
        with snapshotConfiguration: WKSnapshotConfiguration?,
        completionHandler: @escaping @MainActor (NSImage?, (any Error)?) -> Void
    ) {
        completion = completionHandler
        started?.fulfill()
    }

    func completeWithError() {
        let callback = completion
        completion = nil
        callback?(nil, EPUBPageRasterizer.RasterizeError.snapshotFailed)
    }
}
