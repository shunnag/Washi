import WebKit
import XCTest
@testable import Washi

@MainActor
final class NetworkLockdownRuleListTests: XCTestCase {
    func testConcurrentPreparationCompilesAndReportsFailureOnlyOnce() async {
        let probe = RuleCompilationProbe()
        var failures = 0
        var installations = 0
        let rules = NetworkLockdownRuleList(compile: { try await probe.compile() },
            didFail: { error in
                XCTAssertTrue(error is RuleCompilationProbe.Failure)
                failures += 1
            }, didInstall: { _ in installations += 1 })
        let first = Task(priority: .utility) { await rules.prepare() }
        let second = Task(priority: .userInitiated) { await rules.prepare() }
        await fulfillment(of: [probe.started], timeout: 2)
        XCTAssertFalse(rules.installIfReady(in: WKUserContentController()))
        probe.finish(.failure(RuleCompilationProbe.Failure()))
        await first.value
        await second.value
        await rules.prepare()

        XCTAssertEqual(probe.count, 1)
        XCTAssertGreaterThanOrEqual(probe.priority ?? .background, .userInitiated)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(rules.installIfReady(in: WKUserContentController()))
        XCTAssertEqual(installations, 0)
    }

    func testSuccessfulCompilationIsReusedAcrossControllers() async throws {
        let compiled = try await compileLockdownRulesForTest()
        var compilations = 0
        var controllers: [WKUserContentController] = []
        let rules = NetworkLockdownRuleList(compile: {
            compilations += 1
            return compiled
        }, didInstall: { controllers.append($0) })
        let first = WKUserContentController()
        let second = WKUserContentController()
        await rules.prepare()
        XCTAssertTrue(rules.installIfReady(in: first))
        await rules.prepare()
        XCTAssertTrue(rules.installIfReady(in: second))
        XCTAssertEqual(compilations, 1)
        XCTAssertEqual(controllers.count, 2)
        XCTAssertTrue(controllers.first === first)
        XCTAssertTrue(controllers.last === second)
    }
}

@MainActor
final class OffscreenNetworkLockdownTests: XCTestCase {
    func testRuleListIsInstalledBeforeFirstLoadAndAfterHostRecreation() async throws {
        try await assertLoadOrdering(.success(try await compileLockdownRulesForTest()))
    }

    func testCompileFailureIsReportedBeforeLoadAndRenderingCanProceed() async throws {
        try await assertLoadOrdering(.failure(RuleCompilationProbe.Failure()))
    }

    private func assertLoadOrdering(_ result: Result<WKContentRuleList, any Error>) async throws {
        let probe = RuleCompilationProbe()
        var events: [String] = []
        var controllers: [WKUserContentController] = []
        let rules = NetworkLockdownRuleList(compile: { try await probe.compile() },
            didFail: { _ in events.append("failure") },
            didInstall: { controllers.append($0); events.append("install") })
        let host = EPUBOffscreenWebViewHost(networkLockdown: rules)
        defer { host.release() }
        let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>Lockdown</p>")
        func prepare() throws -> URL {
            host.prepare(size: NSSize(width: 480, height: 320),
                allowsScriptedContent: false,
                makeSchemeHandler: { EPUBSchemeHandler(publication: book) })
            let handler = try XCTUnwrap(host.schemeHandler)
            return try XCTUnwrap(handler.url(forReadingOrderItem: book.readingOrder[0]))
        }
        host.navigationLoadHandler = { webView, _ in
            events.append("load")
            XCTAssertGreaterThanOrEqual(Task.currentPriority, .userInitiated)
            // 実 WebContent プロセスに依存せず、読み込み完了だけを返す。
            let waiter = webView.navigationDelegate as? NavigationWaiter
            Task { @MainActor in waiter?.webView(webView, didFinish: nil) }
            return nil
        }
        let url = try prepare()
        let load = Task(priority: .userInitiated) {
            try await host.load(url: url, timeout: .seconds(2))
        }
        await fulfillment(of: [probe.started], timeout: 2)
        XCTAssertTrue(events.isEmpty)
        probe.finish(result)
        try await load.value
        switch result {
        case .success:
            XCTAssertEqual(events, ["install", "load"])
            XCTAssertTrue(controllers.first === host.webView?.configuration.userContentController)
        case .failure:
            XCTAssertEqual(events, ["failure", "load"])
            XCTAssertTrue(controllers.isEmpty)
        }
        // アイドル解放後も、新しいビューには登録してから最初の読み込みを渡す。
        host.release()
        let nextURL = try prepare()
        try await Task(priority: .userInitiated) {
            try await host.load(url: nextURL, timeout: .seconds(2))
        }.value
        XCTAssertEqual(probe.count, 1)
        switch result {
        case .success:
            XCTAssertEqual(events, ["install", "load", "install", "load"])
            XCTAssertTrue(controllers.last === host.webView?.configuration.userContentController)
            XCTAssertFalse(controllers.first === controllers.last)
        case .failure:
            XCTAssertEqual(events, ["failure", "load", "load"])
        }
    }

    func testReleaseDuringCompilationDoesNotLoadDiscardedWebView() async throws {
        let probe = RuleCompilationProbe()
        let rules = NetworkLockdownRuleList(compile: { try await probe.compile() })
        let host = EPUBOffscreenWebViewHost(networkLockdown: rules)
        defer { host.release() }
        let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>Released</p>")
        host.prepare(size: NSSize(width: 480, height: 320), allowsScriptedContent: false,
            makeSchemeHandler: { EPUBSchemeHandler(publication: book) })
        let handler = try XCTUnwrap(host.schemeHandler)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: book.readingOrder[0]))
        var loads = 0
        host.navigationLoadHandler = { _, _ in loads += 1; return nil }
        let load = Task(priority: .userInitiated) {
            try await host.load(url: url, timeout: .seconds(2))
        }
        await fulfillment(of: [probe.started], timeout: 2)
        host.release()
        probe.finish(.failure(RuleCompilationProbe.Failure()))
        do {
            try await load.value
            XCTFail("解放済みの WebView へ読み込んだ")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(loads, 0)
    }

    func testRealOffscreenDocumentStillLoadsAfterCompilationFailure() async throws {
        var failures = 0
        let rules = NetworkLockdownRuleList(compile: { throw RuleCompilationProbe.Failure() },
                                           didFail: { _ in failures += 1 })
        let host = EPUBOffscreenWebViewHost(networkLockdown: rules)
        defer { host.release() }
        let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>Rendered after failure</p>")
        host.prepare(size: NSSize(width: 480, height: 320), allowsScriptedContent: false,
            makeSchemeHandler: { EPUBSchemeHandler(publication: book) })
        let handler = try XCTUnwrap(host.schemeHandler)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: book.readingOrder[0]))
        do {
            try await Task(priority: .userInitiated) {
                try await host.load(url: url, timeout: .seconds(5))
            }.value
        } catch {
            return try failOrSkipIfWebKitUnavailable()
        }
        let webView = try XCTUnwrap(host.webView)
        let text = try await Task(priority: .userInitiated) {
            try await webView.callAsyncJavaScript(
                "return document.body.textContent;", in: nil, contentWorld: .defaultClient) as? String
        }.value
        XCTAssertTrue(text?.contains("Rendered after failure") == true)
        XCTAssertEqual(failures, 1)
    }
}

@MainActor
final class EPUBReaderViewNetworkLockdownTests: XCTestCase {
    func testRuleListIsInstalledBeforeFirstSpineLoadAndRebuild() async throws {
        try await assertLoadOrdering(.success(try await compileLockdownRulesForTest()))
    }

    func testCompileFailureIsReportedBeforeSpineLoadAndRenderingCanProceed() async throws {
        try await assertLoadOrdering(.failure(RuleCompilationProbe.Failure()))
    }

    private func assertLoadOrdering(_ result: Result<WKContentRuleList, any Error>) async throws {
        let probe = RuleCompilationProbe()
        var events: [String] = []
        var controllers: [WKUserContentController] = []
        let rules = NetworkLockdownRuleList(compile: { try await probe.compile() },
            didFail: { _ in events.append("failure") },
            didInstall: { controllers.append($0); events.append("install") })
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.networkLockdown = rules
        defer { view.unload() }
        view.spineLoadHandler = { _ in events.append("load"); return nil }
        let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>Lockdown</p>")
        view.load(publication: book)
        await fulfillment(of: [probe.started], timeout: 2)
        XCTAssertTrue(events.isEmpty)
        probe.finish(result)
        let loaded = await waitUntil(timeout: .seconds(2)) { events.contains("load") }
        XCTAssertTrue(loaded)
        switch result {
        case .success:
            XCTAssertEqual(events, ["install", "load"])
            XCTAssertTrue(controllers.first === view.webView?.configuration.userContentController)
        case .failure:
            XCTAssertEqual(events, ["failure", "load"])
            XCTAssertTrue(controllers.isEmpty)
        }
        // 準備済みなら、既存の同期テストフックも待機を追加せず呼ばれる。
        view.reloadCurrentPublication()
        XCTAssertEqual(probe.count, 1)
        switch result {
        case .success:
            XCTAssertEqual(events, ["install", "load", "install", "load"])
            XCTAssertTrue(controllers.last === view.webView?.configuration.userContentController)
            XCTAssertFalse(controllers.first === controllers.last)
        case .failure:
            XCTAssertEqual(events, ["failure", "load", "load"])
        }
    }

    func testUnloadDuringCompilationDoesNotStartNavigation() async throws {
        try await assertSupersededLoad(unload: true)
    }

    func testBookReplacementDuringCompilationOnlyLoadsNewestBook() async throws {
        try await assertSupersededLoad(unload: false)
    }

    private func assertSupersededLoad(unload: Bool) async throws {
        let probe = RuleCompilationProbe()
        let rules = NetworkLockdownRuleList(compile: { try await probe.compile() })
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.networkLockdown = rules
        defer { view.unload() }
        var requests: [URLRequest] = []
        view.spineLoadHandler = { requests.append($0); return nil }
        let first = try EPUBFixtures.singleSpine(bodyHTML: "<p>Old</p>", name: "lockdown-old")
        let second = try EPUBFixtures.singleSpine(bodyHTML: "<p>New</p>", name: "lockdown-new")
        view.load(publication: first)
        let firstLoad = try XCTUnwrap(view.networkLockdownTask)
        await fulfillment(of: [probe.started], timeout: 2)
        if unload { view.unload() } else { view.load(publication: second) }
        let secondLoad = view.networkLockdownTask
        probe.finish(.failure(RuleCompilationProbe.Failure()))
        await firstLoad.value
        await secondLoad?.value
        XCTAssertEqual(probe.count, 1)
        if unload {
            XCTAssertTrue(requests.isEmpty)
        } else {
            let loaded = await waitUntil(timeout: .seconds(2)) { !requests.isEmpty }
            XCTAssertTrue(loaded)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.host(), view.schemeHandler?.instanceID)
        }
    }

    func testAbandonOrTerminationDuringCompilationDoesNotStartOldNavigation() async throws {
        for terminatesProcess in [false, true] {
            let probe = RuleCompilationProbe()
            let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            view.networkLockdown = NetworkLockdownRuleList(compile: { try await probe.compile() })
            defer { view.unload() }
            var loads = 0
            view.spineLoadHandler = { _ in loads += 1; return nil }
            let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>pending</p>")
            view.load(publication: book)
            let pending = try XCTUnwrap(view.networkLockdownTask)
            await fulfillment(of: [probe.started], timeout: 3)
            if terminatesProcess {
                // ウインドウに載せていないため、再構築は表示復帰まで延期される。
                view.handleWebContentProcessTermination()
                XCTAssertTrue(view.hasPendingWebContentReload)
            } else {
                view.abandonSpineLoad()
            }
            XCTAssertTrue(pending.isCancelled)
            probe.finish(.failure(RuleCompilationProbe.Failure()))
            await pending.value
            XCTAssertEqual(loads, 0)
            XCTAssertNil(view.currentNavigation)
            view.loadSpineItem(at: 0, target: .start)
            XCTAssertEqual(loads, 1, "準備済みの次の発行は待機しない")
            XCTAssertFalse(view.hasPendingWebContentReload)
        }
    }

    func testSameSpineTargetChangeDuringCompilationStillStartsNavigation() async throws {
        let probe = RuleCompilationProbe()
        let rules = NetworkLockdownRuleList(compile: { try await probe.compile() })
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.networkLockdown = rules
        defer { view.unload() }
        var loads = 0
        var evaluations = 0
        view.spineLoadHandler = { [weak view] _ in
            loads += 1
            XCTAssertEqual(view?.currentLocator.progression, 0.75)
            return nil
        }
        view.scriptEvaluationHandler = { _ in evaluations += 1 }
        let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>New target</p>")
        view.load(publication: book)
        let load = try XCTUnwrap(view.networkLockdownTask)
        await fulfillment(of: [probe.started], timeout: 2)
        view.go(to: book.locator(forSpineIndex: 0, progression: 0.75))
        XCTAssertEqual(evaluations, 0)
        probe.finish(.failure(RuleCompilationProbe.Failure()))
        await load.value
        XCTAssertEqual(loads, 1)
    }

    func testRealReaderStillRendersAfterCompilationFailure() async throws {
        var failures = 0
        let rules = NetworkLockdownRuleList(compile: { throw RuleCompilationProbe.Failure() },
                                           didFail: { _ in failures += 1 })
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.networkLockdown = rules
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .unload) }
        let observer = ReaderObservationSpy()
        view.delegate = observer
        let book = try EPUBFixtures.singleSpine(bodyHTML: "<p>Rendered after failure</p>")
        view.load(publication: book)
        let rendered = await waitUntil(timeout: .seconds(5)) { observer.moveCount > 0 }
        guard rendered else { return try failOrSkipIfWebKitUnavailable() }
        XCTAssertTrue(observer.failures.isEmpty)
        XCTAssertEqual(failures, 1)
    }
}

@MainActor
private final class RuleCompilationProbe {
    struct Failure: Error {}
    let started = XCTestExpectation(description: "通信ルールのコンパイル開始")
    private var continuation: CheckedContinuation<WKContentRuleList, any Error>?
    private(set) var count = 0
    private(set) var priority: TaskPriority?

    func compile() async throws -> WKContentRuleList {
        count += 1
        priority = Task.currentPriority
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ result: Result<WKContentRuleList, any Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
private func compileLockdownRulesForTest() async throws -> WKContentRuleList {
    do {
        return try await Task(priority: .userInitiated) {
            try await NetworkLockdownRuleList.compileRules()
        }.value
    } catch {
        try failOrSkipWebKitTest("WKContentRuleList compilation is unavailable: \(error)")
        throw error
    }
}
