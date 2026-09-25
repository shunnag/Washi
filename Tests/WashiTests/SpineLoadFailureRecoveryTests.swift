import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class SpineFailureDelegate: EPUBReaderViewDelegate {
    var moves: [EPUBLocator] = []
    var failures: [any Error] = []
    var failureLocators: [EPUBLocator] = []
    var printPages: [String?] = []
    var edges: [Bool] = []
    var events: [String] = []
    var onFailure: ((EPUBReaderView) -> Void)?

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) { moves.append(locator) }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
        failureLocators.append(view.currentLocator)
        events.append("failure")
        onFailure?(view)
    }
    func readerView(_ view: EPUBReaderView, didChangePrintPage label: String?) {
        printPages.append(label)
    }
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) { edges.append(forward) }
    func readerView(_ view: EPUBReaderView, isPlayingMediaOverlayDidChange playing: Bool) {
        events.append("playing:\(playing)")
    }
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView) { events.append("finished") }
}

@MainActor
final class SpineLoadFailureRecoveryTests: XCTestCase {
    private let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)

    private func publication(unrenderable: Set<String> = ["ch2"]) throws -> EPUBPublication {
        var entries = EPUBFixtures.verticalNovelEntries()
        let opf = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        var package = String(decoding: entries[opf].data, as: UTF8.self)
        for id in unrenderable {
            let original = "<item id=\"\(id)\" href=\"text/\(id).xhtml\" media-type=\"application/xhtml+xml\"/>"
            XCTAssertTrue(package.contains(original), "フィクスチャの OPF が変わった")
            package = package.replacingOccurrences(of: original,
                with: original.replacingOccurrences(of: "application/xhtml+xml", with: "text/html"))
        }
        entries[opf].data = Data(package.utf8)
        let chapter = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/text/ch1.xhtml" })
        // 前章で実際にページを送れる分量と、保持すべき印刷ページを用意する。
        let paragraphs = (0..<40).map {
            "<p>第\($0)段落。" + String(repeating: "吾輩は猫である。名前はまだ無い。", count: 8) + "</p>"
        }.joined()
        entries[chapter].data = Data(EPUBFixtures.chapterXHTML(title: "第一章", body:
            "<span role=\"doc-pagebreak\" id=\"p10\" aria-label=\"10\"></span>"
            + "<p id=\"sec1\">第一章の本文。</p>" + paragraphs).utf8)
        let last = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/text/colophon.xhtml" })
        entries[last].data = Data(EPUBFixtures.chapterXHTML(
            title: "奥付", body: "<p id=\"sec1\">奥付の本文。</p>").utf8)
        let nav = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/nav.xhtml" })
        entries[nav].data = Data(String(decoding: entries[nav].data, as: UTF8.self)
            .replacingOccurrences(of: "</body>", with: """
              <nav epub:type="page-list"><ol>
                <li><a href="text/ch1.xhtml#p10">10</a></li>
                <li><a href="text/ch2.xhtml">20</a></li>
                <li><a href="text/colophon.xhtml">30</a></li>
              </ol></nav></body>
              """).utf8)
        return try makePublication(entries)
    }

    private func makePublication(_ entries: [(name: String, data: Data)]) throws -> EPUBPublication {
        try EPUBPublication(data: ZipBuilder.build(entries, method: 8),
                            displayURL: URL(fileURLWithPath: "/tmp/washi-spine-failure.epub"))
    }

    private func reader() -> (EPUBReaderView, NSWindow, SpineFailureDelegate) {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        view.settings.columnMode = .single
        view.settings.pageTurnStyle = .none
        view.settings.showsPrintPageInFurniture = true
        view.accessibilityReduceMotionOverride = false
        view.accessibilityIncreaseContrastOverride = false
        view.accessibilityDifferentiateWithoutColorOverride = false
        // 自動撮影を止め、必要な控えは同期的に差し込む。
        view.isWindowOnScreenOverride = false
        view.animationFrameWait = { _ in }
        let delegate = SpineFailureDelegate()
        view.delegate = delegate
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, window, delegate)
    }

    private func close(_ view: EPUBReaderView, _ window: NSWindow) {
        view.unload()
        window.contentView = nil
        window.close()
    }

    private func webView(_ view: EPUBReaderView) throws -> WKWebView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
    }

    private func labels(_ view: EPUBReaderView) -> [String] {
        view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func open(_ view: EPUBReaderView, _ book: EPUBPublication,
                      _ delegate: SpineFailureDelegate, at index: Int = 0) async throws {
        view.load(publication: book, at: book.locator(forSpineIndex: index))
        guard await waitUntil({ !delegate.moves.isEmpty }) else {
            return try failOrSkipWebKitTest("WKWebView navigation is unavailable in this sandbox")
        }
        let shown = await waitUntil { (try? self.webView(view).alphaValue) == 1 }
        XCTAssertTrue(shown)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    private func assertRestored(_ view: EPUBReaderView, _ delegate: SpineFailureDelegate,
                                after moves: Int, to index: Int) async throws {
        let web = try webView(view)
        let restored = await waitUntil {
            delegate.moves.count > moves && delegate.moves.last?.spineIndex == index
                && web.alphaValue == 1 && view.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, index)
    }

    private func prepareCover(_ view: EPUBReaderView) throws -> NSImage {
        let web = try webView(view)
        let image = NSImage(size: web.frame.size)
        view.setPrefetchedPageCoverForTesting(.init(
            image: image, rect: web.frame, backingScale: view.window?.backingScaleFactor ?? 2,
            spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem,
            size: view.bounds.size, fontScale: view.settings.fontScale))
        return image
    }

    func testRejectedMoveKeepsThePreviousDocumentInteractive() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        XCTAssertGreaterThan(view.pageCountInItem, 1)
        let web = try webView(view)
        let before = view.currentLocator
        let page = view.pageInItem
        let navigation = view.currentNavigation
        let context = view.mediaOverlayDocumentContext()
        let previousLabels = labels(view)
        let printPages = delegate.printPages.count
        let image = try prepareCover(view)
        // JS と同じ w/h キーで、WebView の座標系の矩形を渡す。
        view.handleScriptMessage(["type": "selection", "text": "本文", "start": 0, "end": 2,
                                  "rects": [["x": 10, "y": 10, "w": 20, "h": 10]]])
        let selection = try XCTUnwrap(view.currentSelection)
        XCTAssertEqual(selection.rects.count, 1)
        XCTAssertFalse(selection.rects[0].isEmpty)

        view.go(to: book.locator(forSpineIndex: 1))

        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(delegate.failureLocators, [before])
        XCTAssertEqual(view.currentLocator, before)
        XCTAssertEqual(view.pageInItem, page)
        XCTAssertTrue(view.currentNavigation === navigation)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertEqual(labels(view), previousLabels)
        XCTAssertEqual(view.currentPrintPage, "10")
        XCTAssertEqual(delegate.printPages.count, printPages)
        XCTAssertEqual(view.currentSelection, selection)
        XCTAssertTrue(view.prefetchedPageCover?.image === image)
        XCTAssertFalse(view.canGoBack)

        // 印なしの偽メッセージでは退行を検出できないので、本物の JS のページ送りを使う。
        let moves = delegate.moves.count
        view.goForward()
        let moved = await waitUntil { delegate.moves.count > moves && view.pageInItem > page }
        XCTAssertTrue(moved)
        XCTAssertEqual(view.currentSpineIndex, 0)
    }

    func testRejectedMoveDoesNotInterruptAnotherLoadOrItsHighlight() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let moves = delegate.moves.count
        let printPages = delegate.printPages.count
        view.go(to: book.locator(forSpineIndex: 2))
        view.mediaOverlayHighlight(fragmentID: "sec1", cssClass: "recovery-test-active")
        let navigation = try XCTUnwrap(view.currentNavigation)
        let context = view.mediaOverlayDocumentContext()
        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(view.currentNavigation === navigation)
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertEqual(delegate.failureLocators.last?.spineIndex, 2)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        XCTAssertEqual(delegate.printPages.count, printPages, "拒否では印刷ページを早く更新しない")
        try await assertRestored(view, delegate, after: moves, to: 2)
        let highlighted = await view.callWashiReturning(
            "return document.querySelector('.recovery-test-active')?.id || ''; ") as? String
        XCTAssertEqual(highlighted, "sec1", "拒否では保留中の読み上げハイライトを捨てない")
    }

    func testProvisionalFailureReloadsThePreviousLocationBeforeNotifying() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let initialMoves = delegate.moves.count
        view.goForward()
        let moved = await waitUntil { delegate.moves.count > initialMoves && view.pageInItem > 0 }
        XCTAssertTrue(moved)
        let before = view.currentLocator
        let moves = delegate.moves.count
        let web = try webView(view)
        view.go(to: book.locator(forSpineIndex: 2))
        view.mediaOverlayHighlight(fragmentID: "sec1", cssClass: "failed-load-active")
        let failedNavigation = try XCTUnwrap(view.currentNavigation)
        view.webView(web, didFailProvisionalNavigation: failedNavigation, withError: failure)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(delegate.failureLocators, [before])
        XCTAssertEqual(view.currentLocator, before)
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertNotNil(view.currentNavigation)
        XCTAssertFalse(view.currentNavigation === failedNavigation)
        XCTAssertTrue(labels(view).isEmpty)
        try await assertRestored(view, delegate, after: moves, to: 0)
        let restoredLocation = await waitUntil {
            view.currentLocator == before && delegate.moves.last == before
        }
        XCTAssertTrue(restoredLocation)
        XCTAssertEqual(view.currentLocator, before)
        XCTAssertEqual(delegate.moves.last, before)
        XCTAssertEqual(delegate.failures.count, 1)
        let highlight = await view.callWashiReturning(
            "return document.querySelector('.failed-load-active')?.id || ''; ") as? String
        XCTAssertEqual(highlight, "", "失敗した読み込みの保留ハイライトを復旧先へ流さない")
    }

    func testCommittedFailureKeepsTheCoverUntilRecoveryFinishes() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let moves = delegate.moves.count
        let image = try prepareCover(view)
        let web = try webView(view)
        view.go(to: book.locator(forSpineIndex: 2))
        let navigation = try XCTUnwrap(view.currentNavigation)
        view.webView(web, didCommit: navigation)
        let cover = try XCTUnwrap(view.pendingSpineTurn?.cover)
        XCTAssertTrue(cover.image === image)
        view.webView(web, didFail: navigation, withError: failure)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(web.alphaValue, 0)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertNotNil(view.currentNavigation)
        XCTAssertTrue(view.pendingSpineTurn?.cover === cover)
        XCTAssertEqual(view.pendingSpineTurn?.animated, false)
        try await assertRestored(view, delegate, after: moves, to: 0)
        XCTAssertNil(cover.superview)
    }

    func testNilLoadDoesNotOverwriteTheRecoveryNavigation() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let web = try webView(view)
        let moves = delegate.moves.count
        var loads = 0
        view.spineLoadHandler = { request in
            loads += 1
            return loads == 1 ? nil : web.load(request)
        }
        view.go(to: book.locator(forSpineIndex: 2))
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertNotNil(view.currentNavigation)
        XCTAssertEqual(web.alphaValue, 1)
        try await assertRestored(view, delegate, after: moves, to: 0)
        XCTAssertFalse(view.deferMediaOverlayHighlightIfLoading(fragmentID: nil, cssClass: "unused"))
    }

    func testRecoveryFailureStopsAndFoldsEveryCover() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let web = try webView(view)
        _ = try prepareCover(view)
        view.go(to: book.locator(forSpineIndex: 2))
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        view.handleNavigationFailure(failure, hasNavigation: true)
        let recovery = try XCTUnwrap(view.currentNavigation)
        XCTAssertEqual(view.pendingSpineTurn?.animated, false)
        view.handleNavigationFailure(failure, hasNavigation: true)
        XCTAssertEqual(delegate.failures.count, 2)
        XCTAssertNil(view.currentNavigation)
        XCTAssertNil(view.armedSpineCover)
        XCTAssertNil(view.pendingSpineTurn)
        XCTAssertTrue(view.turnOverlays.isEmpty)
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertFalse(labels(view).isEmpty)
        XCTAssertFalse(view.deferMediaOverlayHighlightIfLoading(fragmentID: nil, cssClass: "unused"))
        view.webView(web, didFail: recovery, withError: failure)
        XCTAssertEqual(delegate.failures.count, 2, "打ち切った読み込みの遅い通知は捨てる")
    }

    func testUserLoadReplacingRecoveryCanStillRecover() async throws {
        let book = try publication(unrenderable: [])
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let moves = delegate.moves.count
        view.go(to: book.locator(forSpineIndex: 1))
        view.handleNavigationFailure(failure, hasNavigation: true)
        view.go(to: book.locator(forSpineIndex: 2))
        view.handleNavigationFailure(failure, hasNavigation: true)
        XCTAssertEqual(delegate.failures.count, 2)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertNotNil(view.currentNavigation, "利用者の移動に復旧中の印を引き継がない")
        try await assertRestored(view, delegate, after: moves, to: 0)
    }

    func testFailureDelegateCanReplaceRecovery() async throws {
        let book = try publication(unrenderable: [])
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let moves = delegate.moves.count
        delegate.onFailure = { reader in
            XCTAssertEqual(reader.currentSpineIndex, 0)
            reader.go(to: book.locator(forSpineIndex: 1))
        }
        view.go(to: book.locator(forSpineIndex: 2))
        view.handleNavigationFailure(failure, hasNavigation: true)
        XCTAssertEqual(view.currentSpineIndex, 1)
        try await assertRestored(view, delegate, after: moves, to: 1)
        XCTAssertEqual(delegate.failures.count, 1)
    }

    func testFailureWithoutASettledDocumentUpdatesPrintPageBeforeFurniture() throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        view.load(publication: book, at: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertEqual(delegate.failureLocators.last?.spineIndex, 1)
        XCTAssertEqual(view.currentPrintPage, "10")
        XCTAssertEqual(labels(view), ["1 [p. 10]"])
        XCTAssertNil(view.currentNavigation)
        XCTAssertEqual(try webView(view).alphaValue, 1)
    }

    func testNilInitialLoadStopsWithoutAttemptingRecovery() throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        var loads = 0
        view.spineLoadHandler = { _ in loads += 1; return nil }
        view.load(publication: book)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertNil(view.currentNavigation)
        XCTAssertFalse(view.deferMediaOverlayHighlightIfLoading(fragmentID: nil, cssClass: "unused"))
        XCTAssertFalse(labels(view).isEmpty)
    }

    func testBoundaryTurnsSkipUnloadableItemsWithoutFailures() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        view.go(to: book.locator(forSpineIndex: 0, progression: 1))
        let atEnd = await waitUntil { view.pageInItem == view.pageCountInItem - 1 }
        XCTAssertTrue(atEnd)
        let moves = delegate.moves.count
        for _ in 0..<3 { view.handleScriptMessage(["type": "boundary", "forward": true]) }
        XCTAssertTrue(delegate.failures.isEmpty)
        XCTAssertEqual(view.currentSpineIndex, 2)
        try await assertRestored(view, delegate, after: moves, to: 2)
        let backwardMoves = delegate.moves.count
        view.handleScriptMessage(["type": "boundary", "forward": false])
        XCTAssertEqual(view.currentSpineIndex, 0)
        try await assertRestored(view, delegate, after: backwardMoves, to: 0)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testRemainingUnloadableItemsReachBookEdge() async throws {
        let book = try publication(unrenderable: ["ch2", "colophon"])
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let cover = NSImageView(image: NSImage(size: view.bounds.size))
        view.installTurnCover(cover, pending: true)
        for _ in 0..<3 { view.handleScriptMessage(["type": "boundary", "forward": true]) }
        XCTAssertTrue(delegate.failures.isEmpty)
        XCTAssertEqual(delegate.edges, [true, true, true])
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertNil(cover.superview)
    }

    func testFixedLayoutKeyTurnSkipsUnloadablePage() async throws {
        var entries = EPUBFixtures.fxlComicEntries()
        let opf = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        entries[opf].data = Data(String(decoding: entries[opf].data, as: UTF8.self)
            .replacingOccurrences(of: "href=\"p002.xhtml\" media-type=\"application/xhtml+xml\"",
                                  with: "href=\"p002.xhtml\" media-type=\"text/html\"").utf8)
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, makePublication(entries), delegate)
        let moves = delegate.moves.count
        // reader() の pageTurnStyle = .none に固定し、ネイティブの送りから境界へ進める。
        view.goForward()
        XCTAssertEqual(view.currentSpineIndex, 2)
        try await assertRestored(view, delegate, after: moves, to: 2)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testContinuousGroupWithUnloadableMiddleItemReportsOneFailure() async throws {
        var entries = EPUBFixtures.fxlComicEntries()
        let opf = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        entries[opf].data = Data(String(decoding: entries[opf].data, as: UTF8.self)
            .replacingOccurrences(of: "pre-paginated", with: "roll")
            .replacingOccurrences(of: "href=\"p002.xhtml\" media-type=\"application/xhtml+xml\"",
                                  with: "href=\"p002.xhtml\" media-type=\"text/html\"").utf8)
        // 短いページにして、表示不能な中央の項目を初回 setup の先読み範囲に入れる。
        for index in entries.indices where entries[index].name.hasSuffix(".xhtml") {
            entries[index].data = Data(String(decoding: entries[index].data, as: UTF8.self)
                .replacingOccurrences(of: "width=1200, height=1920",
                                      with: "width=1200, height=200").utf8)
        }
        let book = try makePublication(entries)
        XCTAssertEqual(book.scrollGroup(containing: 0), 0..<3)
        XCTAssertFalse(EPUBReaderView.canRenderSpineResource(book.readingOrder[1], in: book))
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        // 初回 AppKit layout の再計測と、同じ setup の二重通知を分けるため先に寸法を確定する。
        try await open(view, publication(unrenderable: []), delegate)
        view.layoutSubtreeIfNeeded()
        let moves = delegate.moves.count
        view.load(publication: book)
        let web = try webView(view)
        let navigation = try XCTUnwrap(view.currentNavigation)
        let failed = await waitUntil { !delegate.failures.isEmpty && web.alphaValue == 1 }
        XCTAssertTrue(failed, "表示準備の失敗処理が終わらない")
        // 同じ WebContent への応答を待ち、setup より前に送られた通知も受け取ってから数える。
        let ready = await view.callWashiReturning("return __washi.scrollMetrics().ready;") as? Bool
        XCTAssertEqual(ready, false)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(delegate.failureLocators.map(\.spineIndex), [0])
        XCTAssertEqual(delegate.moves.count, moves, "表示準備の失敗後に didMoveTo は届かない")
        XCTAssertEqual(view.currentLocator.spineIndex, 0)
        XCTAssertTrue(view.currentNavigation === navigation, "表示準備の失敗では読み込み直さない")
    }

    func testRejectedNavigationKeepsDelayedWebContentReload() throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        view.load(publication: book)
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        view.handleWebContentProcessTermination(at: now)
        view.handleWebContentProcessTermination(at: now)
        XCTAssertTrue(view.hasPendingWebContentReload)
        XCTAssertEqual(view.webContentReloadAttemptCount, 1, "2 回目の終了は遅延再読み込みになる")
        let navigation = view.currentNavigation
        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(view.hasPendingWebContentReload)
        XCTAssertTrue(view.currentNavigation === navigation)
    }

    func testSuppressedWebContentReloadAbandonsLoadAndRestoresFurniture() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let web = try webView(view)
        // 非表示化の後始末でカバーが消えないよう、隠してから読み込みとカバーを用意する。
        view.isHidden = true
        view.go(to: book.locator(forSpineIndex: 2))
        let navigation = try XCTUnwrap(view.currentNavigation)
        view.installTurnCover(NSImageView(image: NSImage(size: view.bounds.size)),
                              pending: true, animated: false)
        XCTAssertNotNil(view.pendingSpineTurn)
        view.mediaOverlayHighlight(fragmentID: "sec1", cssClass: "recovery-test-active")
        // 終了通知だけを注入する。実機では前の文書も WebContent と一緒に失われる。
        // 非表示扱いなので自動復旧は延期され、4 回目で抑止される。
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        for _ in 0..<4 { view.handleWebContentProcessTermination(at: now) }
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertNil(view.currentNavigation)
        XCTAssertNil(view.pendingSpineTurn)
        XCTAssertNil(view.armedSpineCover)
        XCTAssertTrue(view.turnOverlays.isEmpty)
        XCTAssertFalse(view.hasPendingWebContentReload)
        XCTAssertEqual(view.currentPrintPage, "20")
        XCTAssertEqual(labels(view), ["1 [p. 20]"])
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertFalse(view.deferMediaOverlayHighlightIfLoading(fragmentID: nil, cssClass: "unused"))
        view.webView(web, didCommit: navigation)
        XCTAssertEqual(web.alphaValue, 1, "コミット待ちを消し、打ち切ったコミットを無視する")
        view.webView(web, didFail: navigation, withError: failure)
        XCTAssertEqual(delegate.failures.count, 1)
    }

    func testRejectedEntryPointsDoNotRecordHistory() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let context = view.mediaOverlayDocumentContext()
        view.go(to: book.locator(forSpineIndex: 1))
        view.go(to: book.navigation.toc[1])
        view.goToContainerPath(book.readingOrder[1].containerPath, fragment: nil)
        XCTAssertFalse(view.go(toPrintPage: "20"))
        XCTAssertEqual(delegate.failures.count, 4, "各入口は一度だけ拒否を通知する")
        XCTAssertFalse(view.canGoBack)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
    }

    func testRejectedBookStartAndEndKeepTheCurrentLoad() async throws {
        let book = try publication(unrenderable: ["ch1", "colophon"])
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate, at: 1)
        let context = view.mediaOverlayDocumentContext()
        let navigation = view.currentNavigation
        view.goToBookStart()
        view.goToBookEnd()
        XCTAssertEqual(delegate.failures.count, 2)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        XCTAssertTrue(view.currentNavigation === navigation)
        XCTAssertFalse(view.canGoBack)
    }

    func testGoBackRemovesAnUnloadableHistoryEntryAndReportsOneFailure() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        // 初回失敗の項目から表示可能な章へ移り、表示不能な項目を履歴に残す。
        view.load(publication: book, at: book.locator(forSpineIndex: 1))
        view.go(to: book.locator(forSpineIndex: 0))
        let shown = await waitUntil { !delegate.moves.isEmpty && (try? self.webView(view).alphaValue) == 1 }
        guard shown else { return try failOrSkipWebKitTest("WKWebView navigation is unavailable in this sandbox") }
        XCTAssertTrue(view.canGoBack)
        let failures = delegate.failures.count
        let context = view.mediaOverlayDocumentContext()
        view.goBack()
        XCTAssertEqual(delegate.failures.count, failures + 1)
        XCTAssertFalse(view.canGoBack)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        view.goBack()
        XCTAssertEqual(delegate.failures.count, failures + 1, "取り除いた履歴では再び失敗しない")
    }

    func testRejectedBackAllowsFailureDelegateToUnload() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        view.load(publication: book, at: book.locator(forSpineIndex: 1))
        view.go(to: book.locator(forSpineIndex: 0))
        let shown = await waitUntil { !delegate.moves.isEmpty && (try? self.webView(view).alphaValue) == 1 }
        guard shown else { return try failOrSkipWebKitTest("WKWebView navigation is unavailable in this sandbox") }
        XCTAssertTrue(view.canGoBack)
        let failures = delegate.failures.count
        delegate.onFailure = { $0.unload() }

        view.goBack()

        XCTAssertEqual(delegate.failures.count, failures + 1)
        XCTAssertNil(view.publication)
        XCTAssertFalse(view.canGoBack)
    }

    func testRejectedMoveKeepsAnInFlightTextRangeRequest() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        var continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        view.textRangeLocationHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let request = Task { @MainActor in
            await view.go(to: book.locator(forSpineIndex: 0),
                          textRange: (utf16Offset: 0, utf16Length: 1))
        }
        let started = await waitUntil { continuation != nil }
        XCTAssertTrue(started)
        let task = try XCTUnwrap(view.textRangeTask)
        let context = view.mediaOverlayDocumentContext()
        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertFalse(task.isCancelled)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        let landing = EPUBTextRangeLanding(pageInItem: 0, text: "本文", rects: [.zero])
        continuation?.resume(returning: landing)
        let result = await request.value
        XCTAssertEqual(result?.text, landing.text)
        XCTAssertEqual(delegate.failures.count, 1)
    }

    func testSetupFinishedDuringFrameWaitBecomesTheRecoveryLocation() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        var frames: CheckedContinuation<Void, Never>?
        view.animationFrameWaitTimeout = .seconds(30)
        view.animationFrameWait = { _ in await withCheckedContinuation { frames = $0 } }
        defer { frames?.resume() }
        view.go(to: book.locator(forSpineIndex: 2))
        let waiting = await waitUntil { frames != nil && delegate.moves.last?.spineIndex == 2 }
        XCTAssertTrue(waiting)
        let moves = delegate.moves.count
        view.animationFrameWait = { _ in }
        view.go(to: book.locator(forSpineIndex: 0))
        view.handleNavigationFailure(failure, hasNavigation: true)
        XCTAssertEqual(view.currentSpineIndex, 2, "フレーム待ちの前に setup 済みと記録する")
        XCTAssertEqual(delegate.failureLocators.last?.spineIndex, 2)
        frames?.resume()
        frames = nil
        try await assertRestored(view, delegate, after: moves, to: 2)
    }

    func testRejectionDuringFrameWaitKeepsTheAnimatedCover() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        let web = try webView(view)
        var frames: CheckedContinuation<Void, Never>?
        view.animationFrameWaitTimeout = .seconds(30)
        view.animationFrameWait = { _ in await withCheckedContinuation { frames = $0 } }
        defer { frames?.resume() }
        view.go(to: book.locator(forSpineIndex: 2))
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        let cover = NSImageView(image: NSImage(size: view.bounds.size))
        view.installTurnCover(cover, pending: true)
        let waiting = await waitUntil { frames != nil }
        XCTAssertTrue(waiting)
        let context = view.mediaOverlayDocumentContext()
        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(view.pendingSpineTurn?.cover === cover)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        view.animationFrameWait = { _ in }
        frames?.resume()
        frames = nil
        let shown = await waitUntil { web.alphaValue == 1 && view.turnOverlays.isEmpty }
        XCTAssertTrue(shown)
    }

    func testMediaOverlayFinishesWhenItsNextChapterIsRejected() async throws {
        var entries = EPUBFixtures.multiDocumentMediaOverlayEntries()
        let opf = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        entries[opf].data = Data(String(decoding: entries[opf].data, as: UTF8.self)
            .replacingOccurrences(of: "href=\"text/b.xhtml\" media-type=\"application/xhtml+xml\"",
                                  with: "href=\"text/b.xhtml\" media-type=\"text/html\"").utf8)
        let book = try makePublication(entries)
        let (view, window, delegate) = reader()
        defer { close(view, window) }
        try await open(view, book, delegate)
        view.playMediaOverlay()
        XCTAssertTrue(view.isPlayingMediaOverlay)
        let finished = await waitUntil { delegate.events.contains("finished") }
        XCTAssertTrue(finished)
        // highlight(par:) の章移動が拒否され、既存の finish 経路で表示との同期を保つ。
        XCTAssertEqual(delegate.events, ["playing:true", "failure", "playing:false", "finished"])
        XCTAssertFalse(view.isPlayingMediaOverlay)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertEqual(delegate.failures.count, 1)
    }

    func testMissingURLIsASeparatePreflightFailure() throws {
        let book = try publication(unrenderable: [])
        let error = try XCTUnwrap(EPUBReaderView.spineLoadFailure(
            book.readingOrder[0], in: book, url: nil))
        XCTAssertTrue(String(describing: error).contains("Cannot load spine resource:"))
    }

    func testAbandonedSpineLoadPoliciesAreCancelledOnce() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml")
        gate.expect("OEBPS/text/ch2.xhtml")
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
        gate.expect(path)
        gate.abandonPendingExpectations()
        gate.expect(path)

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
        gate.expect(first)
        gate.abandonPendingExpectations()
        gate.expect(origin)  // 最初の復旧。
        gate.expect(second)  // 利用者の移動が復旧を置き換える。
        gate.abandonPendingExpectations()
        gate.expect(origin)  // 同じパスへの二度目の復旧。

        for path in [first, origin, second] {
            XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
        }
        XCTAssertEqual(gate.disposition(for: origin, navigationType: .other), .allowExpectedLoad)
    }

    func testDroppingAbandonedSpineLoadsKeepsExpectedEntries() {
        var gate = SpineNavigationGate()
        let stale = "OEBPS/text/ch2.xhtml"
        let shared = "OEBPS/text/ch1.xhtml"
        let expected = "OEBPS/text/colophon.xhtml"
        gate.expect(stale)
        gate.expect(shared)
        gate.abandonPendingExpectations()
        gate.expect(shared)
        gate.expect(expected)
        gate.dropAbandonedExpectations()

        XCTAssertEqual(gate.disposition(for: stale, navigationType: .other), .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: shared, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: expected, navigationType: .other), .allowExpectedLoad)
    }

    func testCancellingExpectedSpineLoadKeepsAbandonedEntries() {
        var gate = SpineNavigationGate()
        let path = "OEBPS/text/ch1.xhtml"
        gate.expect(path)
        gate.abandonPendingExpectations()
        gate.expect(path)
        gate.expect(path)
        gate.cancelExpectation(for: path)

        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .routeThroughReader)

        gate.expect(path)
        gate.abandonPendingExpectations()
        gate.cancelExpectation(for: path)
        XCTAssertEqual(gate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
    }

    func testUnknownSpineLoadPolicyStillRoutesAfterAbandonment() {
        var gate = SpineNavigationGate()
        let abandoned = "OEBPS/text/ch2.xhtml"
        let recovery = "OEBPS/text/ch1.xhtml"
        gate.expect(abandoned)
        gate.abandonPendingExpectations()
        gate.expect(recovery)

        XCTAssertEqual(gate.disposition(for: "OEBPS/text/other.xhtml", navigationType: .other),
                       .routeThroughReader)
        // 明示的なリンクは従来どおり移動させ、遅配の取消枠を消費しない。
        XCTAssertEqual(gate.disposition(for: abandoned, navigationType: .linkActivated),
                       .routeThroughReader)
        XCTAssertEqual(gate.disposition(for: recovery, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(gate.disposition(for: abandoned, navigationType: .other), .cancelAbandonedLoad)
    }
}
