import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

// cooViewer-mzvd: textOffset 付きの load / go(to:) では、着地前の一時的な位置(連続表示の
// 章頭など)を didMoveTo で報告せず、着地後に実位置の報告が少なくとも 1 回届く。
// 待ちは全て条件のポーリング(固定 sleep なし)。重複報告は実位置なら許す。

@MainActor
final class TextAnchorLandingReportSpy: EPUBReaderViewDelegate {
    struct Report: CustomStringConvertible {
        let spineIndex: Int
        let progression: Double
        let pageInItem: Int
        var description: String {
            "spine=\(spineIndex) p=\(String(format: "%.3f", progression)) page=\(pageInItem)"
        }
    }
    var reports: [Report] = []
    var failures: [any Error] = []

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        reports.append(Report(spineIndex: locator.spineIndex,
                              progression: locator.progression, pageInItem: pageInItem))
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
    }
}

@MainActor
final class TextAnchorLandingReportTests: XCTestCase {
    private var view: EPUBReaderView!
    private var window: NSWindow!
    private var spy: TextAnchorLandingReportSpy!

    override func tearDown() async throws {
        if let view, let window {
            closeReader(view, in: window, teardown: .unload, clearsDelegate: true)
        }
        view = nil
        window = nil
        spy = nil
    }

    private func makeReader(size: CGSize) {
        view = EPUBReaderView(frame: NSRect(origin: .zero, size: size))
        view.settings.insets = .zero
        window = makeOffscreenWindow(containing: view)
        spy = TextAnchorLandingReportSpy()
        view.delegate = spy
    }

    private func pagedBook() throws -> EPUBPublication {
        let body = (0..<300)
            .map { "<p>本文の段落 \($0) です。ここは読書位置の検証用の文章。</p>" }
            .joined()
        return try EPUBFixtures.singleSpine(bodyHTML: body, name: "washi-landing-report")
    }

    private func continuousBook() throws -> EPUBPublication {
        try scrollPublication(flow: "scrolled-continuous", modes: ["horizontal-tb", "horizontal-tb"])
    }

    /// 錨のない進行率の移動が目的の位置に落ち着くまで待つ。連続表示では setup の章頭 scroll の
    /// echo が目的の位置より先に報告され得る(錨のない移動は着地待ちの対象外)ので、
    /// 最初の報告ではなく位置で待つ
    private func waitForProgression(_ progression: Double, file: StaticString = #filePath,
                                    line: UInt = #line) async {
        let settled = await waitUntil(timeout: .seconds(15)) {
            !self.spy.reports.isEmpty
                && abs(self.view.currentLocator.progression - progression) < 0.02
        }
        XCTAssertTrue(settled, "進行率 \(progression) に落ち着かない: \(spy.reports)", file: file, line: line)
    }

    /// 錨への着地が終わり、着地後の報告が届くまで待つ。
    private func waitForLanding(file: StaticString = #filePath, line: UInt = #line) async {
        let landed = await waitUntil(timeout: .seconds(15)) {
            self.view.textRangeTask == nil && !self.view.spineLoad.isAwaitingTextAnchorLanding
        }
        XCTAssertTrue(landed, "着地が終わらない", file: file, line: line)
        let reported = await waitUntil(timeout: .seconds(15)) { !self.spy.reports.isEmpty }
        XCTAssertTrue(reported, "着地後の didMoveTo が届かない", file: file, line: line)
        XCTAssertTrue(spy.failures.isEmpty, spy.failures.description, file: file, line: line)
    }

    /// 報告が 1 回以上あり、全てが着地後の実位置(spine・ページ)で、章頭ではないこと。
    private func assertReportsOnlyAtLandedPosition(
        spineIndex: Int, page: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(spy.reports.count, 1, file: file, line: line)
        XCTAssertEqual(spy.reports.first?.pageInItem, page,
                       "最初の報告が着地位置ではない: \(spy.reports)", file: file, line: line)
        for report in spy.reports {
            XCTAssertEqual(report.spineIndex, spineIndex, "\(spy.reports)", file: file, line: line)
            XCTAssertEqual(report.pageInItem, page, "着地位置以外の報告: \(spy.reports)",
                           file: file, line: line)
        }
    }

    /// 進行率で開いてから錨付きの位置を取る(着地先のページも返す)。
    private func captureAnchor(in book: EPUBPublication, spineIndex: Int,
                               progression: Double) async throws -> EPUBLocator {
        view.load(publication: book, at: book.locator(forSpineIndex: spineIndex, progression: progression))
        await waitForProgression(progression)
        let anchored = await view.currentLocatorWithTextAnchor()
        XCTAssertNotNil(anchored.textOffset, "錨を取得できていない")
        return anchored
    }

    // MARK: - 読み込み(連続表示が退行の再現: setup の章頭 scroll が着地より先に報告していた)

    func testContinuousLoadAtAnchorReportsOnlyTheLandedPosition() async throws {
        makeReader(size: CGSize(width: 500, height: 400))
        let book = try continuousBook()
        let anchored = try await captureAnchor(in: book, spineIndex: 1, progression: 0.55)
        var landedPage: Int?
        for round in 0..<3 {
            spy.reports = []
            view.load(publication: book, at: anchored)
            await waitForLanding()
            let page = view.pageInItem
            XCTAssertGreaterThan(page, 0, "錨の着地先が章頭になっている(round \(round))")
            if let landedPage { XCTAssertEqual(page, landedPage, "round \(round)") }
            landedPage = page
            assertReportsOnlyAtLandedPosition(spineIndex: 1, page: page)
            XCTAssertFalse(spy.reports.contains { $0.progression < 0.01 },
                           "章頭の一時的な位置を報告した(round \(round)): \(spy.reports)")
        }
    }

    func testPagedLoadAtAnchorReportsOnlyTheLandedPosition() async throws {
        makeReader(size: CGSize(width: 480, height: 360))
        let book = try pagedBook()
        let anchored = try await captureAnchor(in: book, spineIndex: 0, progression: 0.5)
        for round in 0..<3 {
            spy.reports = []
            view.load(publication: book, at: anchored)
            await waitForLanding()
            let page = view.pageInItem
            XCTAssertGreaterThan(page, 0, "錨の着地先が章頭になっている(round \(round))")
            assertReportsOnlyAtLandedPosition(spineIndex: 0, page: page)
        }
    }

    func testScrolledDocLoadAtAnchorReportsOnlyTheLandedPosition() async throws {
        makeReader(size: CGSize(width: 500, height: 400))
        let book = try scrollPublication(flow: "scrolled-doc", modes: ["horizontal-tb"])
        let anchored = try await captureAnchor(in: book, spineIndex: 0, progression: 0.6)
        spy.reports = []
        view.load(publication: book, at: anchored)
        await waitForLanding()
        let page = view.pageInItem
        XCTAssertGreaterThan(page, 0, "錨の着地先が章頭になっている")
        assertReportsOnlyAtLandedPosition(spineIndex: 0, page: page)
    }

    // MARK: - 錨が最初の画面にある(scroll が起きない)

    func testAnchorOnFirstScreenStillReportsInPagedMode() async throws {
        makeReader(size: CGSize(width: 480, height: 360))
        let book = try pagedBook()
        var locator = book.locator(forSpineIndex: 0, progression: 0)
        locator.textOffset = 0
        view.load(publication: book, at: locator)
        await waitForLanding()
        assertReportsOnlyAtLandedPosition(spineIndex: 0, page: 0)
    }

    func testAnchorOnFirstScreenStillReportsInContinuousMode() async throws {
        makeReader(size: CGSize(width: 500, height: 400))
        let book = try continuousBook()
        var locator = book.locator(forSpineIndex: 1, progression: 0)
        locator.textOffset = 0
        view.load(publication: book, at: locator)
        await waitForLanding()
        assertReportsOnlyAtLandedPosition(spineIndex: 1, page: 0)
    }

    // MARK: - 錨が見つからない: 進行率へ戻し、その位置だけを報告する

    func testMissingAnchorReportsOnlyTheFallbackPositionInPagedMode() async throws {
        makeReader(size: CGSize(width: 480, height: 360))
        let book = try pagedBook()
        view.load(publication: book, at: book.locator(forSpineIndex: 0, progression: 0.5))
        await waitForProgression(0.5)
        let fallbackPage = view.pageInItem
        XCTAssertGreaterThan(fallbackPage, 0)
        spy.reports = []
        var missing = book.locator(forSpineIndex: 0, progression: 0.5)
        missing.textOffset = 10_000_000
        view.load(publication: book, at: missing)
        await waitForLanding()
        assertReportsOnlyAtLandedPosition(spineIndex: 0, page: fallbackPage)
    }

    func testMissingAnchorReportsOnlyTheFallbackPositionInContinuousMode() async throws {
        makeReader(size: CGSize(width: 500, height: 400))
        let book = try continuousBook()
        view.load(publication: book, at: book.locator(forSpineIndex: 1, progression: 0.55))
        await waitForProgression(0.55)
        let fallbackPage = view.pageInItem
        XCTAssertGreaterThan(fallbackPage, 0)
        spy.reports = []
        var missing = book.locator(forSpineIndex: 1, progression: 0.55)
        missing.textOffset = 10_000_000
        view.load(publication: book, at: missing)
        await waitForLanding()
        assertReportsOnlyAtLandedPosition(spineIndex: 1, page: fallbackPage)
        XCTAssertFalse(spy.reports.contains { $0.progression < 0.01 },
                       "章頭の一時的な位置を報告した: \(spy.reports)")
    }

    // MARK: - 読み込み済みの本での go(to:)

    func testGoToAnchorWhileLoadedReportsOnlyTheLandedPositionInPagedMode() async throws {
        makeReader(size: CGSize(width: 480, height: 360))
        let book = try pagedBook()
        let anchored = try await captureAnchor(in: book, spineIndex: 0, progression: 0.5)
        view.go(to: book.locator(forSpineIndex: 0, progression: 0))
        let atTop = await waitUntil(timeout: .seconds(15)) { self.view.pageInItem == 0 }
        XCTAssertTrue(atTop)
        spy.reports = []
        view.go(to: anchored)
        await waitForLanding()
        let page = view.pageInItem
        XCTAssertGreaterThan(page, 0)
        assertReportsOnlyAtLandedPosition(spineIndex: 0, page: page)
    }

    func testGoToAnchorWhileLoadedReportsOnlyTheLandedPositionInContinuousMode() async throws {
        makeReader(size: CGSize(width: 500, height: 400))
        let book = try continuousBook()
        let anchored = try await captureAnchor(in: book, spineIndex: 1, progression: 0.55)
        view.go(to: book.locator(forSpineIndex: 1, progression: 0))
        let atTop = await waitUntil(timeout: .seconds(15)) {
            self.view.pageInItem == 0 && self.view.textRangeTask == nil
        }
        XCTAssertTrue(atTop)
        spy.reports = []
        view.go(to: anchored)
        await waitForLanding()
        let page = view.pageInItem
        XCTAssertGreaterThan(page, 0)
        assertReportsOnlyAtLandedPosition(spineIndex: 1, page: page)
    }

    // MARK: - 着地待ちの間の利用者のページ送りは報告する

    func testUserPageTurnDuringPendingLandingStillReports() async throws {
        makeReader(size: CGSize(width: 480, height: 360))
        let book = try pagedBook()
        let anchored = try await captureAnchor(in: book, spineIndex: 0, progression: 0.5)
        view.go(to: book.locator(forSpineIndex: 0, progression: 0))
        let atTop = await waitUntil(timeout: .seconds(15)) { self.view.pageInItem == 0 }
        XCTAssertTrue(atTop)
        // JS との境界だけを差し替え、着地を止めたままにする
        var continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        view.textRangeLocationHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        spy.reports = []
        view.go(to: anchored)
        let pending = await waitUntil(timeout: .seconds(5)) { continuation != nil }
        XCTAssertTrue(pending)
        XCTAssertTrue(view.spineLoad.isAwaitingTextAnchorLanding)

        view.goForward()
        XCTAssertFalse(view.spineLoad.isAwaitingTextAnchorLanding, "利用者の操作が抑制を解く")
        let turned = await waitUntil(timeout: .seconds(15)) {
            self.spy.reports.contains { $0.pageInItem == self.view.pagesPerScreen }
        }
        XCTAssertTrue(turned, "着地待ち中のページ送りが報告されない: \(spy.reports)")

        // 着地を見つからなかったことにして片付ける(進行率へ戻る)
        continuation?.resume(returning: nil)
        let settled = await waitUntil(timeout: .seconds(15)) { self.view.textRangeTask == nil }
        XCTAssertTrue(settled)
        view.textRangeLocationHandler = nil
    }

    /// 読み込み中(setup 前)の操作は何も動かせないので、着地を始めるときに待ちへ戻り、
    /// 章頭の echo を漏らさない。
    func testUserInputDuringLoadDoesNotLeakTheChapterTopReport() async throws {
        makeReader(size: CGSize(width: 500, height: 400))
        let book = try continuousBook()
        let anchored = try await captureAnchor(in: book, spineIndex: 1, progression: 0.55)
        spy.reports = []
        view.load(publication: book, at: anchored)
        XCTAssertTrue(view.spineLoad.isLoadingSpineItem)
        XCTAssertTrue(view.spineLoad.isAwaitingTextAnchorLanding)
        view.endTextAnchorLandingWaitForUserInput()
        await waitForLanding()
        let page = view.pageInItem
        XCTAssertGreaterThan(page, 0)
        assertReportsOnlyAtLandedPosition(spineIndex: 1, page: page)
        XCTAssertFalse(spy.reports.contains { $0.progression < 0.01 },
                       "章頭の一時的な位置を報告した: \(spy.reports)")
    }

    // MARK: - WebKit なし: 抑制の範囲と、待ちが解ける経路

    private func makeMockReader() throws -> (EPUBReaderView, EPUBPublication, TextAnchorLandingReportSpy) {
        let publication = try EPUBFixtures.verticalNovel(name: "washi-landing-mock")
        let mock = EPUBReaderView(frame: .zero)
        mock.preparePublication(publication)
        let mockSpy = TextAnchorLandingReportSpy()
        mock.delegate = mockSpy
        return (mock, publication, mockSpy)
    }

    private func pageChanged(page: Int) -> [String: Any] {
        ["type": "pageChanged", "page": page, "pageCount": 12, "pagesPerScreen": 1]
    }

    /// 着地待ちの間の pageChanged は状態には写すが、didMoveTo と復元先の解除だけを見送る。
    /// 着地が終わると次の pageChanged が実位置として届く。
    func testPendingLandingWithholdsOnlyTheReportAndTheRestoreLocator() async throws {
        let (mock, publication, mockSpy) = try makeMockReader()
        defer { mock.unload() }
        var saved = publication.locator(forSpineIndex: 0, progression: 0.25)
        saved.textOffset = 420
        var continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        mock.textRangeLocationHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        mock.go(to: saved)
        let pending = await waitUntil(timeout: .seconds(5)) { continuation != nil }
        XCTAssertTrue(pending)
        XCTAssertTrue(mock.spineLoad.isAwaitingTextAnchorLanding)

        mock.handleScriptMessage(pageChanged(page: 0))
        XCTAssertEqual(mock.pageInItem, 0)
        XCTAssertEqual(mock.pageCountInItem, 12, "ページ数などの状態は更新する")
        XCTAssertTrue(mockSpy.reports.isEmpty, "着地前の位置を報告した: \(mockSpy.reports)")
        XCTAssertEqual(mock.currentLocator.textOffset, 420, "復元先を答え続ける")
        XCTAssertEqual(mock.currentLocator.progression, 0.25)

        continuation?.resume(returning: EPUBTextRangeLanding(
            pageInItem: 7, text: "文", rects: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
        await mock.textRangeTask?.value
        XCTAssertFalse(mock.spineLoad.isAwaitingTextAnchorLanding)
        // 実機では JS の reportPosition が出す再報告に当たる
        mock.handleScriptMessage(pageChanged(page: 7))
        XCTAssertEqual(mockSpy.reports.map(\.pageInItem), [7])
        XCTAssertNil(mock.spineLoad.pendingRestoreLocator)
        XCTAssertNil(mock.currentLocator.textOffset)
    }

    /// 新しい移動は待ちを取り消して自分の位置を報告し、利用者のクリックは着地を
    /// 取り消さずに抑制だけを解く。
    func testNewerNavigationAndUserInputEndTheWait() async throws {
        let (mock, publication, mockSpy) = try makeMockReader()
        defer { mock.unload() }
        var saved = publication.locator(forSpineIndex: 0, progression: 0.25)
        saved.textOffset = 420
        var continuations: [CheckedContinuation<EPUBTextRangeLanding?, Never>] = []
        mock.textRangeLocationHandler = { _, _ in
            await withCheckedContinuation { continuations.append($0) }
        }
        var scripts: [String] = []
        mock.scriptEvaluationHandler = { scripts.append($0) }

        mock.go(to: saved)
        let firstPending = await waitUntil(timeout: .seconds(5)) { continuations.count == 1 }
        XCTAssertTrue(firstPending)
        mock.go(to: publication.locator(forSpineIndex: 0, progression: 0.9))
        XCTAssertFalse(mock.spineLoad.isAwaitingTextAnchorLanding, "新しい移動が待ちを取り消す")
        XCTAssertEqual(scripts, ["__washi.showProgression(0.9);"])
        mock.handleScriptMessage(pageChanged(page: 10))
        XCTAssertEqual(mockSpy.reports.map(\.pageInItem), [10])

        mock.go(to: saved)
        let secondPending = await waitUntil(timeout: .seconds(5)) { continuations.count == 2 }
        XCTAssertTrue(secondPending)
        XCTAssertTrue(mock.spineLoad.isAwaitingTextAnchorLanding)
        mock.dispatchClick(EPUBClickEvent(
            x: 0.5, y: 0.5, locationInView: .zero, button: 0,
            shift: false, option: false, control: false, command: false))
        XCTAssertFalse(mock.spineLoad.isAwaitingTextAnchorLanding, "利用者の操作が抑制を解く")
        XCTAssertNotNil(mock.textRangeTask, "着地そのものは取り消さない")
        mock.handleScriptMessage(pageChanged(page: 3))
        XCTAssertEqual(mockSpy.reports.map(\.pageInItem), [10, 3])

        for continuation in continuations { continuation.resume(returning: nil) }
        await mock.textRangeTask?.value
    }

    /// setup 応答で loading gate が解けてから textRangeTask ができるまでの隙間でも、
    /// 状態は更新しつつホストへの報告だけを見送る。
    func testQueuedTargetSuppressesOnlyHostPositionBeforeTaskExists() throws {
        let mock = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let book = try scrollPublication()
        mock.preparePublication(book)
        defer { mock.unload() }
        let mockSpy = TextAnchorLandingReportSpy()
        mock.delegate = mockSpy
        mock.spineLoad.isLoadingSpineItem = true
        mock.applyOrQueueTarget(.textRange(utf16Offset: 120, utf16Length: 1, fallbackProgression: 0.6))
        XCTAssertNil(mock.textRangeTask)
        XCTAssertTrue(mock.spineLoad.isAwaitingTextAnchorLanding)
        mock.spineLoad.isLoadingSpineItem = false
        let message: [String: Any] = [
            "type": "pageChanged", "page": 2, "pageCount": 9,
            "progression": 0.25, "pagesPerScreen": 2, "mode": "htb",
            "printPageMarkers": [["label": "iii", "page": 2]]
        ]
        let applied = mock.appliedSetupResultCount
        mock.handleScriptMessage(message)
        XCTAssertTrue(mockSpy.reports.isEmpty, "着地前の位置を報告した: \(mockSpy.reports)")
        XCTAssertEqual(mock.currentLocator.textOffset, 120)
        XCTAssertEqual(mock.currentLocator.progression, 0.6)
        XCTAssertEqual(mock.pageInItem, 2)
        XCTAssertEqual(mock.pageCountInItem, 9)
        XCTAssertEqual(mock.scrollProgression, 0.25)
        XCTAssertEqual(mock.pagesPerScreen, 2)
        XCTAssertEqual(mock.appliedSetupResultCount, applied + 1)
        XCTAssertEqual(mock.printPageMarkers.map(\.label), ["iii"])

        mock.endTextAnchorLandingWaitForUserInput()
        mock.handleScriptMessage(message)
        XCTAssertEqual(mockSpy.reports.count, 1)
        XCTAssertNil(mock.spineLoad.pendingRestoreLocator)
        XCTAssertEqual(mock.currentLocator.progression, 0.25)
    }

    /// 旧文書の着地の応答は、次の spine 読み込みが立てた錨待ちを解かない。unload は解く。
    func testOldSpineReplyCannotCloseTheNewLandingWindow() async throws {
        let (mock, publication, _) = try makeMockReader()
        defer { mock.unload() }
        var reply: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        mock.textRangeLocationHandler = { _, _ in await withCheckedContinuation { reply = $0 } }
        var locator = publication.locator(forSpineIndex: 0)
        locator.textOffset = 120
        mock.go(to: locator)
        let task = try XCTUnwrap(mock.textRangeTask)
        let started = await waitUntil(timeout: .seconds(5)) { reply != nil }
        XCTAssertTrue(started)
        mock.spineLoadGeneration += 1
        mock.spineLoad.isAwaitingTextAnchorLanding = true
        reply?.resume(returning: nil)
        await task.value
        XCTAssertTrue(mock.spineLoad.isAwaitingTextAnchorLanding, "旧文書の応答が新しい待ちを解いた")
        mock.unload()
        XCTAssertFalse(mock.spineLoad.isAwaitingTextAnchorLanding)
    }

    /// コンテナが受けたキーは配送の前に待ちを解き、着地は取り消さない。
    func testUserKeyRoutingEndsTheWaitWithoutCancellingTheLanding() async throws {
        let (mock, publication, _) = try makeMockReader()
        defer { mock.unload() }
        var reply: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        mock.textRangeLocationHandler = { _, _ in await withCheckedContinuation { reply = $0 } }
        var locator = publication.locator(forSpineIndex: 0)
        locator.textOffset = 120
        mock.go(to: locator)
        let task = try XCTUnwrap(mock.textRangeTask)
        let started = await waitUntil(timeout: .seconds(5)) { reply != nil }
        XCTAssertTrue(started)
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49))
        var forwarded = false
        mock.routeKeyDown(with: key) { _ in forwarded = true }
        XCTAssertTrue(forwarded)
        XCTAssertFalse(mock.spineLoad.isAwaitingTextAnchorLanding, "キーが待ちを解く")
        XCTAssertNotNil(mock.textRangeTask, "着地そのものは取り消さない")
        reply?.resume(returning: EPUBTextRangeLanding(
            pageInItem: 0, text: "本文", rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]))
        await task.value
    }
}
