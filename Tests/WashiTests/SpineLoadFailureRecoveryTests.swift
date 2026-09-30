import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
final class SpineLoadFailureRecoveryTests: XCTestCase {
    private let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)

    private func publication(unrenderable: Set<String> = ["ch2"]) throws -> EPUBPublication {
        var entries = EPUBFixtures.verticalNovelEntries()
        for id in unrenderable {
            let original = "<item id=\"\(id)\" href=\"text/\(id).xhtml\" media-type=\"application/xhtml+xml\"/>"
            entries = try EPUBFixtures.replacing(entries, in: "OEBPS/package.opf", of: original,
                with: original.replacingOccurrences(of: "application/xhtml+xml", with: "text/html"))
        }
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
        entries = try EPUBFixtures.replacing(entries, in: "OEBPS/nav.xhtml", of: "</body>", with: """
              <nav epub:type="page-list"><ol>
                <li><a href="text/ch1.xhtml#p10">10</a></li>
                <li><a href="text/ch2.xhtml">20</a></li>
                <li><a href="text/colophon.xhtml">30</a></li>
              </ol></nav></body>
              """)
        return try makePublication(entries)
    }

    private func makePublication(_ entries: [(name: String, data: Data)]) throws -> EPUBPublication {
        try EPUBFixtures.publication(entries, name: "washi-spine-failure")
    }

    private func reader() -> (EPUBReaderView, NSWindow, ReaderObservationSpy) {
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
        let delegate = ReaderObservationSpy()
        view.delegate = delegate
        let window = makeOffscreenWindow(containing: view, ignoresMouseEvents: false)
        return (view, window, delegate)
    }

    private func labels(_ view: EPUBReaderView) -> [String] {
        view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    }

    private func open(_ view: EPUBReaderView, _ book: EPUBPublication,
                      _ delegate: ReaderObservationSpy, at index: Int = 0) async throws {
        view.load(publication: book, at: book.locator(forSpineIndex: index))
        guard await waitUntil(timeout: .seconds(8), poll: .milliseconds(5), { !delegate.moves.isEmpty }) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { (try? view.firstWebView().alphaValue) == 1 }
        XCTAssertTrue(shown)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    private func assertRestored(_ view: EPUBReaderView, _ delegate: ReaderObservationSpy,
                                after moves: Int, to index: Int) async throws {
        let web = try view.firstWebView()
        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moves.count > moves && delegate.moves.last?.spineIndex == index
                && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, index)
    }

    private func prepareCover(_ view: EPUBReaderView) throws -> NSImage {
        let web = try view.firstWebView()
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        XCTAssertGreaterThan(view.pageCountInItem, 1)
        let web = try view.firstWebView()
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
        XCTAssertTrue(view.pageCover.prefetchedPageCover?.image === image)
        XCTAssertFalse(view.canGoBack)

        // 印なしの偽メッセージでは退行を検出できないので、本物の JS のページ送りを使う。
        let moves = delegate.moves.count
        view.goForward()
        let moved = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { delegate.moves.count > moves && view.pageInItem > page }
        XCTAssertTrue(moved)
        XCTAssertEqual(view.currentSpineIndex, 0)
    }

    func testRejectedMoveDoesNotInterruptAnotherLoadOrItsHighlight() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        let initialMoves = delegate.moves.count
        view.goForward()
        let moved = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { delegate.moves.count > initialMoves && view.pageInItem > 0 }
        XCTAssertTrue(moved)
        let before = view.currentLocator
        let moves = delegate.moves.count
        let web = try view.firstWebView()
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
        let restoredLocation = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        let moves = delegate.moves.count
        let image = try prepareCover(view)
        let web = try view.firstWebView()
        view.go(to: book.locator(forSpineIndex: 2))
        let navigation = try XCTUnwrap(view.currentNavigation)
        view.webView(web, didCommit: navigation)
        let cover = try XCTUnwrap(view.turn.pendingSpineTurn?.cover)
        XCTAssertTrue(cover.image === image)
        view.webView(web, didFail: navigation, withError: failure)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(web.alphaValue, 0)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertNotNil(view.currentNavigation)
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover === cover)
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, false)
        try await assertRestored(view, delegate, after: moves, to: 0)
        XCTAssertNil(cover.superview)
    }

    func testNilLoadDoesNotOverwriteTheRecoveryNavigation() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        let web = try view.firstWebView()
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        let web = try view.firstWebView()
        _ = try prepareCover(view)
        view.go(to: book.locator(forSpineIndex: 2))
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        view.handleNavigationFailure(failure, hasNavigation: true)
        let recovery = try XCTUnwrap(view.currentNavigation)
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, false)
        view.handleNavigationFailure(failure, hasNavigation: true)
        XCTAssertEqual(delegate.failures.count, 2)
        XCTAssertNil(view.currentNavigation)
        XCTAssertNil(view.pageCover.armedSpineCover)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertTrue(view.turn.turnOverlays.isEmpty)
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertFalse(labels(view).isEmpty)
        XCTAssertFalse(view.deferMediaOverlayHighlightIfLoading(fragmentID: nil, cssClass: "unused"))
        view.webView(web, didFail: recovery, withError: failure)
        XCTAssertEqual(delegate.failures.count, 2, "打ち切った読み込みの遅い通知は捨てる")
    }

    func testUserLoadReplacingRecoveryCanStillRecover() async throws {
        let book = try publication(unrenderable: [])
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
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
        defer { closeReader(view, in: window, teardown: .unload) }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        view.load(publication: book, at: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertEqual(delegate.failureLocators.last?.spineIndex, 1)
        XCTAssertEqual(view.currentPrintPage, "10")
        XCTAssertEqual(labels(view), ["1 [p. 10]"])
        XCTAssertNil(view.currentNavigation)
        XCTAssertEqual(try view.firstWebView().alphaValue, 1)
    }

    func testNilInitialLoadStopsWithoutAttemptingRecovery() throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        view.go(to: book.locator(forSpineIndex: 0, progression: 1))
        let atEnd = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { view.pageInItem == view.pageCountInItem - 1 }
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
        defer { closeReader(view, in: window, teardown: .unload) }
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
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: "href=\"p002.xhtml\" media-type=\"application/xhtml+xml\"",
            with: "href=\"p002.xhtml\" media-type=\"text/html\"")
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
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
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf", of: "pre-paginated", with: "roll")
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: "href=\"p002.xhtml\" media-type=\"application/xhtml+xml\"",
            with: "href=\"p002.xhtml\" media-type=\"text/html\"")
        // 短いページにして、表示不能な中央の項目を初回 setup の先読み範囲に入れる。
        for index in entries.indices where entries[index].name.hasSuffix(".xhtml") {
            entries[index].data = Data(String(decoding: entries[index].data, as: UTF8.self)
                .replacingOccurrences(of: "width=1200, height=1920",
                                      with: "width=1200, height=200").utf8)
        }
        let book = try makePublication(entries)
        XCTAssertEqual(book.scrollGroup(containing: 0), 0..<3)
        XCTAssertFalse(book.canRenderSpineResource(book.readingOrder[1]))
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
        // 初回 AppKit layout の再計測と、同じ setup の二重通知を分けるため先に寸法を確定する。
        try await open(view, publication(unrenderable: []), delegate)
        view.layoutSubtreeIfNeeded()
        let moves = delegate.moves.count
        view.load(publication: book)
        let web = try view.firstWebView()
        let navigation = try XCTUnwrap(view.currentNavigation)
        let failed = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { !delegate.failures.isEmpty && web.alphaValue == 1 }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        view.load(publication: book)
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        view.handleWebContentProcessTermination(at: now)
        view.handleWebContentProcessTermination(at: now)
        XCTAssertTrue(view.hasPendingWebContentReload)
        XCTAssertEqual(view.webContentReload.attemptCount, 1, "2 回目の終了は遅延再読み込みになる")
        let navigation = view.currentNavigation
        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(view.hasPendingWebContentReload)
        XCTAssertTrue(view.currentNavigation === navigation)
    }

    func testSuppressedWebContentReloadAbandonsLoadAndRestoresFurniture() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        let web = try view.firstWebView()
        // 非表示化の後始末でカバーが消えないよう、隠してから読み込みとカバーを用意する。
        view.isHidden = true
        view.go(to: book.locator(forSpineIndex: 2))
        let navigation = try XCTUnwrap(view.currentNavigation)
        view.installTurnCover(NSImageView(image: NSImage(size: view.bounds.size)),
                              pending: true, animated: false)
        XCTAssertNotNil(view.turn.pendingSpineTurn)
        view.mediaOverlayHighlight(fragmentID: "sec1", cssClass: "recovery-test-active")
        // 終了通知だけを注入する。実機では前の文書も WebContent と一緒に失われる。
        // 非表示扱いなので自動復旧は延期され、4 回目で抑止される。
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        for _ in 0..<4 { view.handleWebContentProcessTermination(at: now) }
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertNil(view.currentNavigation)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertNil(view.pageCover.armedSpineCover)
        XCTAssertTrue(view.turn.turnOverlays.isEmpty)
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

    func testSamePathLoadSucceedsAfterWebContentTerminationBeforePolicy() async throws {
        for flow in ["paginated", "scrolled-continuous"] {
            let book = try scrollPublication(flow: flow, modes: Array(repeating: "horizontal-tb", count: 3))
            for terminationCount in [3, 4] {
                let (view, window, delegate) = reader()
                defer { closeReader(view, in: window, teardown: .unload) }
                try await open(view, book, delegate)
                let web = try view.firstWebView()
                let previousNavigation = try XCTUnwrap(view.currentNavigation)
                let moves = delegate.moves.count
                view.isHidden = true
                var lostURL: URL?
                // WebKit へ渡さず navigation だけ返し、プロセスと共に消えた policy 待ちを作る。
                // 実際に load/stopLoading すると、終了通知の注入後にも判定が届いてしまう。
                view.spineLoadHandler = { request in
                    lostURL = request.url
                    return previousNavigation
                }
                view.goToBookEnd()
                let url = try XCTUnwrap(lostURL)
                let now = Date(timeIntervalSinceReferenceDate: 6_000)
                for _ in 0..<terminationCount { view.handleWebContentProcessTermination(at: now) }
                XCTAssertEqual(view.hasPendingWebContentReload, terminationCount == 3)
                XCTAssertEqual(delegate.failures.count, terminationCount == 4 ? 1 : 0)

                // 自動再構築が延期・抑止された同じ WebView で、同じパスを実際に読み込む。
                view.spineLoadHandler = { request in
                    XCTAssertEqual(request.url, url)
                    return web.load(request)
                }
                view.goToBookEnd()
                view.spineLoadHandler = nil
                XCTAssertFalse(view.hasPendingWebContentReload)
                view.isHidden = false

                try await assertRestored(view, delegate, after: moves, to: 2)
                XCTAssertTrue(try view.firstWebView() === web)
                XCTAssertEqual(view.webContentReload.attemptCount, 0)
                XCTAssertEqual(delegate.failures.count, terminationCount == 4 ? 1 : 0)
            }
        }
    }

    func testRejectedEntryPointsDoNotRecordHistory() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
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
        defer { closeReader(view, in: window, teardown: .unload) }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        // 初回失敗の項目から表示可能な章へ移り、表示不能な項目を履歴に残す。
        view.load(publication: book, at: book.locator(forSpineIndex: 1))
        view.go(to: book.locator(forSpineIndex: 0))
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { !delegate.moves.isEmpty && (try? view.firstWebView().alphaValue) == 1 }
        guard shown else { return try failOrSkipIfWebKitUnavailable() }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        view.load(publication: book, at: book.locator(forSpineIndex: 1))
        view.go(to: book.locator(forSpineIndex: 0))
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { !delegate.moves.isEmpty && (try? view.firstWebView().alphaValue) == 1 }
        guard shown else { return try failOrSkipIfWebKitUnavailable() }
        XCTAssertTrue(view.canGoBack)
        let failures = delegate.failures.count
        delegate.onFailure = { $0.unload() }

        view.goBack()

        XCTAssertEqual(delegate.failures.count, failures + 1)
        XCTAssertNil(view.publication)
        XCTAssertFalse(view.canGoBack)
    }

    func testReentrantBackRejectsEachUnloadableHistoryEntryOnce() async throws {
        let book = try publication(unrenderable: ["ch1", "ch2"])
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
        // 文書をまだ表示していない間に失敗した二つの項目を履歴に積む。
        view.load(publication: book, at: book.locator(forSpineIndex: 0))
        view.go(to: book.locator(forSpineIndex: 1))
        view.go(to: book.locator(forSpineIndex: 2))
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { !delegate.moves.isEmpty && (try? view.firstWebView().alphaValue) == 1 }
        guard shown else { return try failOrSkipIfWebKitUnavailable() }
        XCTAssertTrue(view.canGoBack)
        let failures = delegate.failures.count
        var historyAvailability: [Bool] = []
        delegate.onFailure = { reader in
            historyAvailability.append(reader.canGoBack)
            if historyAvailability.count == 1 { reader.goBack() }
        }

        view.goBack()

        XCTAssertEqual(delegate.failures.count, failures + 2)
        let rejected = delegate.failures.dropFirst(failures).map { String(describing: $0) }
        XCTAssertTrue(try XCTUnwrap(rejected.first).contains("ch2.xhtml"))
        XCTAssertTrue(try XCTUnwrap(rejected.last).contains("ch1.xhtml"))
        XCTAssertEqual(historyAvailability, [true, false], "失敗通知より前に履歴と利用可否を更新する")
        XCTAssertFalse(view.canGoBack)
        XCTAssertEqual(view.currentSpineIndex, 2)
        view.goBack()
        XCTAssertEqual(delegate.failures.count, failures + 2)
    }

    func testRejectedMoveKeepsAnInFlightTextRangeRequest() async throws {
        let book = try publication()
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        var continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        view.textRangeLocationHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let request = Task { @MainActor in
            await view.go(to: book.locator(forSpineIndex: 0),
                          textRange: (utf16Offset: 0, utf16Length: 1))
        }
        let started = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { continuation != nil }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        var frames: CheckedContinuation<Void, Never>?
        view.animationFrameWaitTimeout = .seconds(30)
        view.animationFrameWait = { _ in await withCheckedContinuation { frames = $0 } }
        defer { frames?.resume() }
        view.go(to: book.locator(forSpineIndex: 2))
        let waiting = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { frames != nil && delegate.moves.last?.spineIndex == 2 }
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
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        let web = try view.firstWebView()
        var frames: CheckedContinuation<Void, Never>?
        view.animationFrameWaitTimeout = .seconds(30)
        view.animationFrameWait = { _ in await withCheckedContinuation { frames = $0 } }
        defer { frames?.resume() }
        view.go(to: book.locator(forSpineIndex: 2))
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        let cover = NSImageView(image: NSImage(size: view.bounds.size))
        view.installTurnCover(cover, pending: true)
        let waiting = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { frames != nil }
        XCTAssertTrue(waiting)
        let context = view.mediaOverlayDocumentContext()
        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover === cover)
        XCTAssertEqual(view.mediaOverlayDocumentContext(), context)
        view.animationFrameWait = { _ in }
        frames?.resume()
        frames = nil
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { web.alphaValue == 1 && view.turn.turnOverlays.isEmpty }
        XCTAssertTrue(shown)
    }

    func testMediaOverlayFinishesWhenItsNextChapterIsRejected() async throws {
        var entries = EPUBFixtures.multiDocumentMediaOverlayEntries()
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: "href=\"text/b.xhtml\" media-type=\"application/xhtml+xml\"",
            with: "href=\"text/b.xhtml\" media-type=\"text/html\"")
        let book = try makePublication(entries)
        let (view, window, delegate) = reader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await open(view, book, delegate)
        view.playMediaOverlay()
        XCTAssertTrue(view.isPlayingMediaOverlay)
        let finished = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { delegate.events.contains("finished") }
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
}
