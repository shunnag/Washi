import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class ReentrantReaderDelegate: EPUBReaderViewDelegate {
    var onHistoryChanged: ((EPUBReaderView) -> Void)?
    var onMove: ((EPUBReaderView) -> Void)?
    var onInternalLink: ((EPUBReaderView) -> Bool)?
    var onClick: ((EPUBReaderView) -> Bool)?
    var moveCount = 0
    var animationCount = 0
    var failures: [any Error] = []

    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {
        onHistoryChanged?(view)
    }

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moveCount += 1
        onMove?(view)
    }

    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool {
        onInternalLink?(view) ?? true
    }

    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool {
        onClick?(view) ?? false
    }

    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool {
        animationCount += 1
        return true
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
    }
}

@MainActor
final class EPUBReaderReentrancyTests: XCTestCase {
    private func publication(_ name: String, fixed: Bool = false) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(fixed ? EPUBFixtures.fxlComicEntries()
                                  : EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/\(name).epub"))
    }

    func testHistoryCallbackLoadingAnotherBookSupersedesOriginalJump() throws {
        let original = try publication("original")
        let replacement = try publication("replacement")
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: original)
        let latest = replacement.locator(forSpineIndex: 0, progression: 0.75)
        delegate.onHistoryChanged = { view in
            delegate.onHistoryChanged = nil
            view.load(publication: replacement, at: latest)
        }

        view.go(to: original.locator(forSpineIndex: 1, progression: 0.2))

        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentLocator, latest)
        XCTAssertFalse(view.canGoBack)
    }

    func testHistoryCallbackNavigationSupersedesOriginalJumpInSameBook() throws {
        let book = try publication("same-book")
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: book)
        let latest = book.locator(forSpineIndex: 0, progression: 0.75)
        delegate.onHistoryChanged = { view in
            delegate.onHistoryChanged = nil
            view.go(to: latest)
        }

        view.go(to: book.locator(forSpineIndex: 1, progression: 0.2))

        XCTAssertEqual(view.currentLocator, latest)
    }

    func testHistoryResetCallbackLoadingAnotherBookKeepsItsWebView() throws {
        let original = try publication("original")
        let replacement = try publication("replacement")
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: original)
        view.go(to: original.locator(forSpineIndex: 1, progression: 0.2))
        let latest = replacement.locator(forSpineIndex: 1, progression: 0.75)
        var replacementWebView: WKWebView?
        delegate.onHistoryChanged = { view in
            delegate.onHistoryChanged = nil
            view.load(publication: replacement, at: latest)
            replacementWebView = view.subviews.first { $0 is WKWebView } as? WKWebView
        }

        view.load(publication: original)

        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentLocator, latest)
        XCTAssertTrue(view.subviews.contains { $0 === replacementWebView })
    }

    func testDetachedWebViewFailureDoesNotAffectReplacementBook() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: try publication("original"))
        let detached = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)
        let replacement = try publication("replacement")
        let latest = replacement.locator(forSpineIndex: 1, progression: 0.75)
        view.load(publication: replacement, at: latest)
        let current = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)

        view.webView(detached, didFail: nil,
                     withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))

        XCTAssertTrue(delegate.failures.isEmpty)
        XCTAssertEqual(current.alphaValue, 0)
        XCTAssertEqual(view.currentLocator, latest)
        XCTAssertNil(detached.navigationDelegate)
        XCTAssertNil(detached.uiDelegate)
    }

    func testHistoryResetCallbackCanNavigateOnlyAfterNewBookIsInstalled() throws {
        let original = try publication("original")
        let replacement = try publication("replacement")
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: original)
        let oldWebView = try XCTUnwrap(view.subviews.first { $0 is WKWebView })
        view.go(to: original.locator(forSpineIndex: 1, progression: 0.2))
        let latest = replacement.locator(forSpineIndex: 1, progression: 0.75)
        delegate.onHistoryChanged = { view in
            delegate.onHistoryChanged = nil
            view.go(to: latest)
        }

        view.load(publication: replacement)

        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentLocator, latest)
        XCTAssertFalse(view.subviews.contains { $0 === oldWebView })
    }

    func testTextRangeRequestCancelledByHistoryCallbackDoesNotMoveReplacementBook() async throws {
        let original = try publication("original")
        let replacement = try publication("replacement")
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: original)
        let latest = replacement.locator(forSpineIndex: 0, progression: 0.75)
        delegate.onHistoryChanged = { view in
            delegate.onHistoryChanged = nil
            view.load(publication: replacement, at: latest)
        }

        let result = await view.go(
            to: original.locator(forSpineIndex: 1, progression: 0.2),
            textRange: (utf16Offset: 0, utf16Length: 1))

        XCTAssertNil(result)
        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentLocator, latest)
    }

    func testInternalLinkPolicyOpeningAnotherBookCancelsOldLinkNavigation() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: try publication("original"))
        let replacement = try publication("replacement")
        let latest = replacement.locator(forSpineIndex: 0, progression: 0.75)
        delegate.onInternalLink = { view in
            view.load(publication: replacement, at: latest)
            return true
        }

        view.handleScriptMessage(["type": "link", "href": "ch2.xhtml"])

        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentLocator, latest)
        XCTAssertFalse(view.canGoBack)
    }

    func testClickDelegateOpeningAnotherBookCancelsDefaultTurn() throws {
        let view = EPUBReaderView(frame: .zero)
        view.settings.pageTurnStyle = .none
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        view.load(publication: try publication("original-fxl", fixed: true))
        let replacement = try publication("replacement-fxl", fixed: true)
        delegate.onClick = { view in
            view.load(publication: replacement)
            return false
        }

        view.handleScriptMessage(["type": "tap", "x": 0.9, "y": 0.5, "button": 0])

        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentSpineIndex, 0)
    }

    func testPageChangeCallbackOpeningAnotherBookCancelsInFlightAnimation() async throws {
        // CI の Reduce Motion 設定は変更せず、このビューだけで演出を検証する。
        let original = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.singleSpineEntries(
                bodyHTML: String(repeating: "<p>ページめくり中の本の差し替えを検証する本文です。</p>", count: 150)), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/in-flight-reflow.epub"))
        let replacement = try publication("replacement-fxl", fixed: true)
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings.pageTurnStyle = .fade
        view.accessibilityReduceMotionOverride = false
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.cancelPageCensus()
            view.delegate = nil
            window.contentView = nil
            window.close()
        }
        view.load(publication: original)
        for _ in 0..<250 where delegate.moveCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard delegate.moveCount > 0 else {
            return try failOrSkipWebKitTest("WKWebView navigation is unavailable in this sandbox")
        }
        XCTAssertGreaterThan(view.pageCountInItem, 1)
        var sawInFlightCover = false
        delegate.onMove = { view in
            delegate.onMove = nil
            sawInFlightCover = !view.turnOverlays.isEmpty
            view.load(publication: replacement)
        }

        view.goForward()
        let turn = try XCTUnwrap(view.lastAnimatedTurnTask)
        await turn.value

        XCTAssertTrue(sawInFlightCover, "スナップショット失敗による演出なしの経路では検証にならない")
        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertEqual(delegate.animationCount, 0)
        XCTAssertTrue(view.turnOverlays.isEmpty)
    }

    func testScheduledAnimatedTurnDoesNotAdvanceReplacementBook() async throws {
        // 予約済みの演出が実行される前に本を差し替え、その演出の終了まで待つ。
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings.pageTurnStyle = .fade
        view.accessibilityReduceMotionOverride = false
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.cancelPageCensus()
            view.delegate = nil
            window.contentView = nil
            window.close()
        }
        view.load(publication: try publication("original-fxl", fixed: true))
        for _ in 0..<250 where delegate.moveCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard delegate.moveCount > 0 else {
            return try failOrSkipWebKitTest("WKWebView navigation is unavailable in this sandbox")
        }
        let replacement = try publication("replacement-fxl", fixed: true)

        view.goForward()
        let turn = try XCTUnwrap(view.lastAnimatedTurnTask)
        view.load(publication: replacement)
        await turn.value

        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertEqual(delegate.animationCount, 0)
        XCTAssertTrue(view.turnOverlays.isEmpty)
    }

    func testReduceMotionUsesSystemSettingUnlessOverridden() {
        let view = EPUBReaderView(frame: .zero)
        XCTAssertEqual(view.accessibilityShouldReduceMotion,
                       NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        view.accessibilityReduceMotionOverride = false
        XCTAssertFalse(view.accessibilityShouldReduceMotion)
        view.accessibilityReduceMotionOverride = true
        XCTAssertTrue(view.accessibilityShouldReduceMotion)
        view.accessibilityReduceMotionOverride = nil
        XCTAssertEqual(view.accessibilityShouldReduceMotion,
                       NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func testReduceMotionDisablesAnimationWithoutPreventingNavigation() async throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings.pageTurnStyle = .fade
        view.accessibilityReduceMotionOverride = true
        let delegate = ReentrantReaderDelegate()
        view.delegate = delegate
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.unload()
            window.contentView = nil
            window.close()
        }
        view.load(publication: try publication("reduced-motion-fxl", fixed: true))
        for _ in 0..<250 where delegate.moveCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard delegate.moveCount > 0 else {
            return try failOrSkipWebKitTest("WKWebView navigation is unavailable in this sandbox")
        }

        view.goForward()

        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertNil(view.lastAnimatedTurnTask)
        XCTAssertEqual(delegate.animationCount, 0)
        XCTAssertTrue(view.turnOverlays.isEmpty)
    }
}
