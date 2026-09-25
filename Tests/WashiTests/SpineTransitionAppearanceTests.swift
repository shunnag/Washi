import AppKit
import WebKit
import XCTest
@testable import Washi

// spine 遷移の見え方の取り決め:
// 1. 読み込みの開始では透明にしない(前のページはコミットまで見えている)
// 2. 描画フレームの待ちは必ず打ち切られ、取り消しにも即座に応じる
// 3. 控えのカバーは条件が一致したときだけ、撮った矩形に貼られ、表示が戻ると畳まれる

/// ページ割りの通知を数える。WebKit がこの環境で動くかを alpha と無関係に見る
@MainActor
private final class MoveCountingDelegate: EPUBReaderViewDelegate {
    var moves = 0
    var failures: [any Error] = []
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moves += 1
    }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
    }
}

@MainActor
final class SpineTransitionAppearanceTests: XCTestCase {
    private func makePublication(_ name: String = "washi-spine-transition") throws
        -> EPUBPublication
    {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/\(name).epub"))
    }

    /// 2 番目の項目(ch2)を text/html と宣言し、描画可能な fallback の無い項目にする
    private func makePublicationWithUnrenderableSecondItem() throws -> EPUBPublication {
        var entries = EPUBFixtures.verticalNovelEntries()
        let opf = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        let original = String(decoding: entries[opf].data, as: UTF8.self)
        let patched = original.replacingOccurrences(
            of: #"<item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>"#,
            with: #"<item id="ch2" href="text/ch2.xhtml" media-type="text/html"/>"#)
        XCTAssertNotEqual(patched, original, "フィクスチャの OPF が変わった")
        entries[opf].data = Data(patched.utf8)
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-unrenderable-second.epub"))
        XCTAssertFalse(EPUBReaderView.canRenderSpineResource(publication.readingOrder[1], in: publication))
        return publication
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                size: view.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        return window
    }

    private func webView(of view: EPUBReaderView) throws -> WKWebView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
    }

    private func waitUntil(
        timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// 本を開き、最初の表示が戻るまで待つ。WebKit が使えなければ skip する
    private func openAndSettle(_ view: EPUBReaderView, _ publication: EPUBPublication,
                               delegate: MoveCountingDelegate) async throws {
        view.delegate = delegate
        view.load(publication: publication)
        guard await waitUntil({ delegate.moves > 0 }) else {
            return try failOrSkipWebKitTest(
                "WKWebView navigation is unavailable in this sandbox")
        }
        let shown = await waitUntil { (try? self.webView(of: view).alphaValue) == 1 }
        XCTAssertTrue(shown)
    }

    private func cover(for view: EPUBReaderView, rect: NSRect,
                       spineIndex: Int = 0, pageInItem: Int = 0)
        -> EPUBReaderView.PrefetchedPageCover
    {
        EPUBReaderView.PrefetchedPageCover(
            image: NSImage(size: rect.size), rect: rect,
            backingScale: view.window?.backingScaleFactor ?? 2,
            spineIndex: spineIndex, pageInItem: pageInItem,
            size: view.bounds.size, fontScale: view.settings.fontScale)
    }

    // MARK: - 描画フレームの待ち

    func testFrameWaitGivesUpAtTheTimeout() async {
        let start = ContinuousClock.now
        let completed = await EPUBReaderView.race(
            { try? await Task.sleep(for: .seconds(30)) }, timeout: .milliseconds(50))
        XCTAssertFalse(completed)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testFrameWaitReportsCompletion() async {
        let completed = await EPUBReaderView.race({}, timeout: .seconds(30))
        XCTAssertTrue(completed)
    }

    /// 取り消されたら、打ち切り時間を待たずに戻る(メインスレッドを回し続けない)
    func testFrameWaitReturnsPromptlyWhenCancelled() async {
        let start = ContinuousClock.now
        let task = Task { @MainActor in
            await EPUBReaderView.race(
                { try? await Task.sleep(for: .seconds(30)) }, timeout: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let completed = await task.value
        XCTAssertFalse(completed)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    /// 描画フレームが進まないまま打ち切られた待ちが、閉じたリーダーの WebView を
    /// 保持し続けない(最小化・遮蔽中に本を閉じても WebContent プロセスが残らない)。
    /// rAF を止める方法は WebKit の版で効き方が違うので、決して解決しない script で
    /// 同じ待ちの経路を通す
    func testTimedOutFrameWaitDoesNotRetainWebView() async throws {
        let views = NSHashTable<WKWebView>.weakObjects()
        do {
            let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let window = makeWindow(containing: view)
            defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
            try await openAndSettle(view, try makePublication(), delegate: MoveCountingDelegate())
            let web = try webView(of: view)
            views.add(web)
            let completed = await EPUBReaderView.race({
                await EPUBReaderView.waitForWashiScript(
                    "await new Promise(() => {}); return true;", in: web)
            }, timeout: .milliseconds(100))
            XCTAssertFalse(completed)
            view.unload()
        }
        for _ in 0..<500 {
            if autoreleasepool(invoking: { views.allObjects.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(views.allObjects.isEmpty, "打ち切った描画フレーム待ちが WebView を保持している")
    }

    /// 描画フレームが進まなくても、表示は打ち切り時間の後に必ず戻る
    func testAlphaIsRestoredWhenAnimationFramesNeverArrive() async throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        view.animationFrameWait = { _ in try? await Task.sleep(for: .seconds(30)) }
        view.animationFrameWaitTimeout = .milliseconds(100)
        try await openAndSettle(view, try makePublication(), delegate: MoveCountingDelegate())
    }

    // MARK: - 透明化の時点

    /// 読み込みの開始では透明にしない(透明にするのは didCommit)
    func testLoadingTheNextItemDoesNotHideThePreviousPage() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        try await openAndSettle(view, publication, delegate: MoveCountingDelegate())
        XCTAssertGreaterThan(publication.readingOrder.count, 1)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertEqual(try webView(of: view).alphaValue, 1)
    }

    /// コミットまでは前のページが見えているので、新しい項目のノンブルを出さない
    func testPageNumbersAreHiddenUntilTheNextItemCommits() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        try await openAndSettle(view, publication, delegate: MoveCountingDelegate())
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(labels.allSatisfy(\.isHidden))
    }

    /// 表示できない項目への移動に失敗したら、現在の状態でノンブルを出し直す
    func testPageNumbersReturnWhenTheNextItemCannotBeDisplayed() async throws {
        let publication = try makePublicationWithUnrenderableSecondItem()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = false
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        let delegate = MoveCountingDelegate()
        try await openAndSettle(view, publication, delegate: delegate)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(try webView(of: view).alphaValue, 1)
        // 失敗後も失敗した項目を指す既存の状態を前提として確かめる
        XCTAssertEqual(view.currentSpineIndex, 1)
        // 現在の状態（失敗した項目の先頭）と一致する
        XCTAssertEqual(labels.filter { !$0.isHidden }.map(\.stringValue), ["1"])
    }

    /// 読み込みの失敗後に、現在の状態でノンブルを出し直す
    func testPageNumbersReturnWhenLoadingTheNextItemFails() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = false
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        let delegate = MoveCountingDelegate()
        try await openAndSettle(view, publication, delegate: delegate)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(labels.allSatisfy(\.isHidden))
        view.handleNavigationFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData),
            hasNavigation: true)
        XCTAssertEqual(delegate.failures.count, 1)
        // 現在の状態（失敗した項目の先頭）と一致する
        XCTAssertEqual(labels.filter { !$0.isHidden }.map(\.stringValue), ["1"])
    }

    /// 境界めくりに失敗したら、持ち越しカバーを畳んでノンブルを出し直す
    func testPageNumbersReturnWhenABoundaryTurnCannotBeDisplayed() async throws {
        let publication = try makePublicationWithUnrenderableSecondItem()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = false
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        let delegate = MoveCountingDelegate()
        try await openAndSettle(view, publication, delegate: delegate)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        view.installTurnCover(NSImageView(image: NSImage(size: view.bounds.size)), pending: true)
        view.handleScriptMessage(["type": "boundary", "forward": true])
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertNil(view.pendingSpineTurn)
        XCTAssertTrue(view.turnOverlays.isEmpty)
        // 現在の状態（失敗した項目の先頭）と一致する
        XCTAssertEqual(labels.filter { !$0.isHidden }.map(\.stringValue), ["1"])
    }

    // MARK: - 控えのカバー

    /// 撮ったときの表示条件と 1 つでも食い違えば使わない
    func testPrefetchedCoverMatchesOnlyTheSameDisplayConditions() {
        let base = EPUBReaderView.PrefetchedPageCover(
            image: NSImage(), rect: .zero, backingScale: 2, spineIndex: 3,
            pageInItem: 4, size: NSSize(width: 800, height: 600), fontScale: 1)
        func matches(spineIndex: Int = 3, pageInItem: Int = 4,
                     size: NSSize = NSSize(width: 800, height: 600),
                     fontScale: Double = 1, backingScale: CGFloat = 2) -> Bool {
            base.matches(spineIndex: spineIndex, pageInItem: pageInItem, size: size,
                         fontScale: fontScale, backingScale: backingScale)
        }
        XCTAssertTrue(matches())
        XCTAssertFalse(matches(spineIndex: 2), "spine")
        XCTAssertFalse(matches(pageInItem: 5), "page")
        XCTAssertFalse(matches(size: NSSize(width: 801, height: 600)), "size")
        XCTAssertFalse(matches(fontScale: 1.1), "font scale")
        XCTAssertFalse(matches(backingScale: 1), "backing scale")
    }

    /// 用意された控えは didCommit で撮った矩形に貼られ、表示が戻ると畳まれる
    func testPreparedCoverIsInstalledAtCommitAndFoldedAfterDisplay() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var settings = view.settings
        settings.pageTurnStyle = .none
        view.settings = settings
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        try await openAndSettle(view, publication, delegate: MoveCountingDelegate())
        // カバーが見えている間を確実に観測できるよう、表示の復帰を打ち切りまで遅らせる
        view.animationFrameWait = { _ in try? await Task.sleep(for: .seconds(30)) }
        view.animationFrameWaitTimeout = .milliseconds(400)
        let rect = NSRect(x: 12, y: 34, width: 200, height: 150)
        let prepared = cover(for: view, rect: rect,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        view.setPrefetchedPageCoverForTesting(prepared)

        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.armedSpineCover?.image === prepared.image, "離れるページの控えを取り置く")
        let installed = await waitUntil {
            view.pendingSpineTurn?.cover.image === prepared.image
        }
        XCTAssertTrue(installed, "didCommit でカバーとして貼られる")
        let cover = try XCTUnwrap(view.pendingSpineTurn?.cover)
        XCTAssertEqual(cover.frame, rect, "撮った矩形に置く")
        XCTAssertTrue(view.turnOverlays.contains { $0 === cover })
        XCTAssertEqual(try webView(of: view).alphaValue, 0)

        let folded = await waitUntil {
            (try? self.webView(of: view).alphaValue) == 1 && view.turnOverlays.isEmpty
        }
        XCTAssertTrue(folded, "表示が戻ったらカバーを畳む")
        XCTAssertNil(view.pendingSpineTurn)
    }

    /// 演出ありの送り(既定の slide)では控えを使わない
    func testCoverIsNotUsedWithAnimatedPageTurns() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // CI ランナーには視差効果を減らす設定が有効なものがあるので、OS 設定に依存させない
        view.accessibilityReduceMotionOverride = false
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        try await openAndSettle(view, publication, delegate: MoveCountingDelegate())
        XCTAssertEqual(view.settings.pageTurnStyle, .slide)
        view.setPrefetchedPageCoverForTesting(cover(
            for: view, rect: view.bounds,
            spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem))
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertNil(view.armedSpineCover)
    }

    /// 視差効果を減らす設定では演出が省かれるので、slide でも控えを使う
    func testCoverIsUsedWithAnimatedPageTurnsWhenReducingMotion() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = true
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        try await openAndSettle(view, publication, delegate: MoveCountingDelegate())
        XCTAssertEqual(view.settings.pageTurnStyle, .slide)
        let prepared = cover(for: view, rect: view.bounds,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        view.setPrefetchedPageCoverForTesting(prepared)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.armedSpineCover?.image === prepared.image)
    }

    /// 前の本の控えを次の本に貼らない
    func testCoverDoesNotSurviveOpeningAnotherBook() throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var settings = view.settings
        settings.pageTurnStyle = .none
        view.settings = settings
        view.load(publication: try makePublication("washi-book-a"))
        view.setPrefetchedPageCoverForTesting(cover(for: view, rect: view.bounds))
        view.load(publication: try makePublication("washi-book-b"))
        XCTAssertNil(view.prefetchedPageCover)
        XCTAssertNil(view.armedSpineCover)

        view.setPrefetchedPageCoverForTesting(cover(for: view, rect: view.bounds))
        view.unload()
        XCTAssertNil(view.prefetchedPageCover)
        XCTAssertNil(view.armedSpineCover)
    }

    /// 控えが無い遷移はカバー無しで最後まで進む
    func testTransitionWithoutAPrefetchedCoverFallsBack() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var settings = view.settings
        settings.pageTurnStyle = .none
        view.settings = settings
        let window = makeWindow(containing: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        try await openAndSettle(view, publication, delegate: MoveCountingDelegate())
        XCTAssertGreaterThan(publication.readingOrder.count, 2)
        view.setPrefetchedPageCoverForTesting(nil)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        XCTAssertNil(view.armedSpineCover)
        XCTAssertNil(view.prefetchedPageCover)
        let restored = await waitUntil {
            (try? self.webView(of: view).alphaValue) == 1 && view.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertNil(view.pendingSpineTurn)
    }
}
