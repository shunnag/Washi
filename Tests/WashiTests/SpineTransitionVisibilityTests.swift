import AppKit
import WebKit
import XCTest
@testable import Washi

// spine 遷移の見え方(描画フレームの待ちと透明化の時点)。取り決めの全体は
// PageCoverTestSupport.swift を参照

@MainActor
final class SpineTransitionVisibilityTests: XCTestCase {
    private func makePublication(_ name: String = "washi-spine-transition") throws
        -> EPUBPublication
    {
        try EPUBFixtures.verticalNovel(name: name)
    }

    // MARK: - 描画フレームの待ち

    func testFrameWaitGivesUpAtTheTimeout() async {
        let start = ContinuousClock.now
        let completed = await TimeoutRace.run(
            { try? await Task.sleep(for: .seconds(30)) }, timeout: .milliseconds(50))
        XCTAssertFalse(completed)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testFrameWaitReportsCompletion() async {
        let completed = await TimeoutRace.run({}, timeout: .seconds(30))
        XCTAssertTrue(completed)
    }

    /// 取り消されたら、打ち切り時間を待たずに戻る(メインスレッドを回し続けない)
    func testFrameWaitReturnsPromptlyWhenCancelled() async {
        let start = ContinuousClock.now
        let task = Task { @MainActor in
            await TimeoutRace.run(
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
            let window = makeOffscreenWindow(containing: view)
            defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
            try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
            let web = try view.firstWebView()
            views.add(web)
            let completed = await TimeoutRace.run({
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
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        view.animationFrameWait = { _ in try? await Task.sleep(for: .seconds(30)) }
        view.animationFrameWaitTimeout = .milliseconds(100)
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
    }

    // MARK: - 透明化の時点

    /// 読み込みの開始では透明にしない(透明にするのは didCommit)
    func testLoadingTheNextItemDoesNotHideThePreviousPage() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
        XCTAssertGreaterThan(publication.readingOrder.count, 1)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertEqual(try view.firstWebView().alphaValue, 1)
    }

    /// 置き換えた読み込みのコミットでも、ページ割り前の文書を隠す(Washi-7ct)
    func testSupersededLoadCommitHidesTheUnpaginatedDocument() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = false
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        XCTAssertGreaterThan(publication.readingOrder.count, 2)
        let web = try view.firstWebView()
        view.setPrefetchedPageCoverForTesting(nil)
        let moves = delegate.moveCount

        // await を挟まず、先行のコミットが次の読み込みの開始後に届く順序を再現する
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        let superseded = try XCTUnwrap(view.currentNavigation)
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        XCTAssertTrue(view.currentNavigation !== superseded)
        XCTAssertEqual(web.alphaValue, 1, "どちらもコミット前なので前のページが見えている")
        view.webView(web, didCommit: superseded)
        XCTAssertEqual(web.alphaValue, 0, "ページ割り前の文書を見せない")

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored, "次の読み込みのコミットと setup の後に表示が戻る")
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertNil(view.turn.pendingSpineTurn)
    }

    /// 修正の前後とも成功する、ガードの広げすぎを防ぐテスト。
    /// 表示が落ち着いた後の古いコミットは、今のページを隠さない。
    func testLateCommitOfAnEarlierLoadDoesNotHideASettledPage() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = false
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        let web = try view.firstWebView()
        let initial = try XCTUnwrap(view.currentNavigation)

        let m = delegate.moveCount
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        let settled = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { delegate.moveCount > m && web.alphaValue == 1 }
        XCTAssertTrue(settled)
        let frame = web.frame

        view.webView(web, didCommit: initial)
        XCTAssertEqual(web.alphaValue, 1, "表示済みのページは古いコミットで隠さない")
        XCTAssertEqual(web.frame, frame, "表示済みのページの矩形を変えない")
    }

    /// コミットまでは前のページが見えているので、新しい項目のノンブルを出さない
    func testPageNumbersAreHiddenUntilTheNextItemCommits() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(labels.allSatisfy(\.isHidden))
    }

    /// 表示できない項目への移動を拒否したら、移動前のノンブルをそのまま保つ。
    func testPageNumbersReturnWhenTheNextItemCannotBeDisplayed() async throws {
        let publication = try makePublicationWithUnrenderableSecondItem()
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        let previousLabels = labels.filter { !$0.isHidden }.map(\.stringValue)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(try view.firstWebView().alphaValue, 1)
        // 拒否では位置もノンブルも移動前のまま保つ。
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertEqual(labels.filter { !$0.isHidden }.map(\.stringValue), previousLabels)
    }

    /// 読み込みの失敗後は移動元を読み込み直し、その表示とノンブルを戻す。
    func testPageNumbersReturnWhenLoadingTheNextItemFails() async throws {
        let publication = try makePublication()
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        let previousLabels = labels.filter { !$0.isHidden }.map(\.stringValue)
        let previousMoves = delegate.moveCount
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(labels.allSatisfy(\.isHidden))
        view.handleNavigationFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData),
            hasNavigation: true)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertTrue(labels.allSatisfy(\.isHidden), "読み込み直しの間は隠す")
        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > previousMoves && (try? view.firstWebView().alphaValue) == 1
                && view.turn.pendingSpineTurn == nil
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(labels.filter { !$0.isHidden }.map(\.stringValue), previousLabels)
    }

    /// 境界めくりは表示不能な項目を飛ばし、次の項目の表示後にノンブルを出す。
    func testPageNumbersReturnWhenABoundaryTurnCannotBeDisplayed() async throws {
        let publication = try makePublicationWithUnrenderableSecondItem()
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { !$0.isHidden }, "ノンブルが見えている前提")
        let cover = NSImageView(image: NSImage(size: view.bounds.size))
        view.installTurnCover(cover, pending: true)
        let previousMoves = delegate.moveCount
        view.handleScriptMessage(["type": "boundary", "forward": true])
        XCTAssertEqual(delegate.failures.count, 0)
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover === cover)
        XCTAssertTrue(labels.allSatisfy(\.isHidden))
        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > previousMoves && (try? view.firstWebView().alphaValue) == 1
                && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertTrue(view.turn.turnOverlays.isEmpty)
        XCTAssertTrue(labels.contains { !$0.isHidden })
    }
}
