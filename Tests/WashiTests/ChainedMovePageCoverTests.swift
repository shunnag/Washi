import AppKit
import WebKit
import XCTest
@testable import Washi

// 連続した移動での控えの引き継ぎ(Washi-3b1)。取り決めの全体は
// PageCoverTestSupport.swift を参照

@MainActor
final class ChainedMovePageCoverTests: XCTestCase {
    private func makePublication(_ name: String = "washi-spine-transition") throws
        -> EPUBPublication
    {
        try EPUBFixtures.verticalNovel(name: name)
    }

    // MARK: - 連続した移動での控えの引き継ぎ(Washi-3b1)

    func testChainedMoveBeforeTheCommitKeepsThePreviousPageCover() async throws {
        let publication = try makePublication()
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        XCTAssertGreaterThan(publication.readingOrder.count, 2)
        let web = try view.firstWebView()
        let rect = NSRect(x: 12, y: 34, width: 200, height: 150)
        let prepared = cover(for: view, rect: rect,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let moves = delegate.moveCount

        // await を挟まず、前の読み込みのコミットを待つ間に次の移動が始まる順序を再現する
        view.setPrefetchedPageCoverForTesting(prepared)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image, "離れるページの控えを取り置く")
        let superseded = try XCTUnwrap(view.currentNavigation)
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image,
                      "前のページが見えている間は、取り置いた控えを次の移動に引き継ぐ")
        XCTAssertEqual(web.alphaValue, 1)
        view.webView(web, didCommit: superseded)
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover.image === prepared.image,
                      "置き換えた読み込みのコミットで控えを貼る")
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, false)
        XCTAssertEqual(view.turn.pendingSpineTurn?.cover.frame, rect, "撮った矩形に置く")
        XCTAssertEqual(view.turn.turnOverlays.count, 1)
        XCTAssertNil(view.pageCover.armedSpineCover)
        XCTAssertEqual(web.alphaValue, 0)

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored, "最新の項目の表示が戻ったら控えを畳む")
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testFixedLayoutKeyRepeatKeepsThePreviousPageCoverWhenReducingMotion() async throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-fxl-chain")
        let (view, window) = makeChainReader(reduceMotion: true, pageTurnStyle: .slide)
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        XCTAssertEqual(publication.readingOrder.count, 3)
        let web = try view.firstWebView()
        let prepared = cover(for: view, rect: web.frame,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let moves = delegate.moveCount

        view.setPrefetchedPageCoverForTesting(prepared)
        view.goForward()
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertNil(view.turn.pendingSpineTurn, "視差効果を減らす設定では演出のカバーを作らない")
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image)
        view.goForward()
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image,
                      "キーの長押しでも前のページの控えを引き継ぐ")

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertNil(view.pageCover.armedSpineCover)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testThreeChainedMovesUseTheFirstCoverUntilTheLastItemIsShown() async throws {
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, try makePublication(), delegate: delegate)
        // 実際のコミットで貼ったカバーを観測できるよう、表示の復帰を打ち切りまで遅らせる
        view.animationFrameWait = { _ in try? await Task.sleep(for: .seconds(30)) }
        view.animationFrameWaitTimeout = .milliseconds(400)
        let web = try view.firstWebView()
        let prepared = cover(for: view, rect: web.frame,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let moves = delegate.moveCount

        view.setPrefetchedPageCoverForTesting(prepared)
        for index in [1, 2, 1] {
            view.go(to: EPUBLocator(spineIndex: index, progression: 0))
            XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image, "\(index) への移動")
        }
        // 修正前は控えが貼られず、この待ちは 8 秒で時間切れになる
        let installed = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            view.turn.pendingSpineTurn?.cover.image === prepared.image
        }
        XCTAssertTrue(installed, "どの読み込みのコミットが先に届いても控えを貼る")

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testChainedMoveDoesNotKeepTheCoverAfterTheDisplayConditionsChange() async throws {
        for change in ["pageTurnStyle", "fontScale"] {
            let publication = try makePublication()
            let (view, window) = makeChainReader()
            defer { closeReader(view, in: window, teardown: .unload) }
            let delegate = ReaderObservationSpy()
            try await openAndSettle(view, publication, delegate: delegate)
            let web = try view.firstWebView()
            let prepared = cover(for: view, rect: web.frame,
                                 spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
            let moves = delegate.moveCount

            view.setPrefetchedPageCoverForTesting(prepared)
            view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
            XCTAssertNotNil(view.pageCover.armedSpineCover, change)
            if change == "pageTurnStyle" {
                view.settings.pageTurnStyle = .slide
            } else {
                view.settings.fontScale = 1.25
            }
            XCTAssertNotNil(view.pageCover.armedSpineCover,
                            "\(change): 設定の変更そのものでは取り置きを捨てない")
            view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
            XCTAssertNil(view.pageCover.armedSpineCover, change)

            let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
                delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
            }
            XCTAssertTrue(restored, change)
            XCTAssertEqual(view.currentSpineIndex, 2, change)
            XCTAssertNil(view.turn.pendingSpineTurn, change)
            XCTAssertTrue(delegate.failures.isEmpty, change)
        }
    }

    func testJumpAfterTheCommitKeepsThePreviousPageCover() async throws {
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, try makePublication(), delegate: delegate)
        let web = try view.firstWebView()
        let prepared = cover(for: view, rect: web.frame,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let moves = delegate.moveCount

        view.setPrefetchedPageCoverForTesting(prepared)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        let installed = try XCTUnwrap(view.turn.pendingSpineTurn?.cover, "コミットで控えを貼る")
        XCTAssertTrue(installed.image === prepared.image)
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, false)
        XCTAssertEqual(web.alphaValue, 0)
        // 表示が整う前に目次などで移動する
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover === installed, "移動しても控えのカバーを畳まない")
        XCTAssertTrue(installed.superview === view)
        XCTAssertEqual(view.turn.turnOverlays.count, 1)

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored, "最新の項目の表示が戻ったら控えを畳む")
        XCTAssertNil(installed.superview)
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testRebuildingTheWebViewFoldsThePreviousPageCover() async throws {
        for rebuild in ["anotherBook", "reload"] {
            let (view, window) = makeChainReader()
            defer { closeReader(view, in: window, teardown: .unload) }
            let delegate = ReaderObservationSpy()
            try await openAndSettle(view, try makePublication(), delegate: delegate)
            let web = try view.firstWebView()
            let prepared = cover(for: view, rect: web.frame,
                                 spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)

            view.setPrefetchedPageCoverForTesting(prepared)
            view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
            view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
            let installed = try XCTUnwrap(view.turn.pendingSpineTurn?.cover, rebuild)
            XCTAssertTrue(installed.image === prepared.image, rebuild)
            if rebuild == "anotherBook" {
                view.load(publication: try makePublication("washi-chain-b"))
            } else {
                view.settings.allowsScriptedContent.toggle()
            }
            XCTAssertNil(view.turn.pendingSpineTurn, rebuild)
            XCTAssertTrue(view.turn.turnOverlays.isEmpty, rebuild)
            XCTAssertNil(installed.superview, rebuild)
            XCTAssertNil(view.pageCover.armedSpineCover, rebuild)
        }
    }

    func testFailureInAChainKeepsTheCoverUntilRecoveryFinishes() async throws {
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, try makePublication(), delegate: delegate)
        let web = try view.firstWebView()
        let prepared = cover(for: view, rect: web.frame,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let previousMoves = delegate.moveCount
        view.setPrefetchedPageCoverForTesting(prepared)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        view.handleNavigationFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData),
            hasNavigation: true)
        // コミット前の復旧は最初の文書の控えを引き継ぎ、復旧のコミットで貼る。
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertTrue(view.turn.turnOverlays.isEmpty)
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(view.currentSpineIndex, 0)
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        XCTAssertTrue(view.turn.pendingSpineTurn?.oldPage === prepared.image)
        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > previousMoves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertNil(view.turn.pendingSpineTurn)
    }

    func testChainedMoveThroughAScrolledItemKeepsThePreviousPageCover() async throws {
        var entries = EPUBFixtures.verticalNovelEntries()
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: #"<itemref idref="ch2"/>"#,
            with: #"<itemref idref="ch2" properties="rendition:flow-scrolled-doc"/>"#)
        let publication = try EPUBFixtures.publication(entries, name: "washi-scrolled-chain")
        XCTAssertTrue(EPUBScreenMetrics.isScrolled(publication.renderingFlow(at: 1)))
        XCTAssertFalse(EPUBScreenMetrics.isScrolled(publication.renderingFlow(at: 0)))
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        let web = try view.firstWebView()
        let prepared = cover(for: view, rect: web.frame,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let moves = delegate.moveCount

        view.setPrefetchedPageCoverForTesting(prepared)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image)
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image,
                      "途中の項目がスクロールでも、見えている前のページの控えを引き継ぐ")

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, 2)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testJumpStillFoldsAnAnimatedTurnCover() async throws {
        let (view, window) = makeChainReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, try makePublication(), delegate: delegate)
        let web = try view.firstWebView()
        let moves = delegate.moveCount
        let cover = NSImageView(image: NSImage(size: view.bounds.size))

        view.installTurnCover(cover, pending: true)
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, true)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertNil(cover.superview)
        XCTAssertTrue(view.turn.turnOverlays.isEmpty)

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testKeyRepeatAtTheBookEndKeepsTheSnapshotCover() async throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-fxl-chain-end")
        let (view, window) = makeChainReader(reduceMotion: true, pageTurnStyle: .slide)
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        XCTAssertEqual(publication.readingOrder.count, 3)
        let web = try view.firstWebView()
        let prepared = cover(for: view, rect: web.frame,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        let moves = delegate.moveCount

        view.setPrefetchedPageCoverForTesting(prepared)
        view.goForward()
        XCTAssertEqual(view.currentSpineIndex, 1)
        view.webView(web, didCommit: try XCTUnwrap(view.currentNavigation))
        let installed = try XCTUnwrap(view.turn.pendingSpineTurn?.cover)
        XCTAssertTrue(installed.image === prepared.image)
        view.goForward()
        XCTAssertEqual(view.currentSpineIndex, publication.readingOrder.count - 1)
        let lastNavigation = try XCTUnwrap(view.currentNavigation)
        view.webView(web, didCommit: lastNavigation)
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover === installed)
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, false)
        // 最後の項目の setup 前にキーリピートが本の端に当たる
        view.goForward()
        XCTAssertTrue(view.currentNavigation === lastNavigation)
        XCTAssertTrue(view.turn.pendingSpineTurn?.cover === installed,
                      "本の端でも最後の項目の表示が戻るまで控えを残す")
        XCTAssertEqual(view.turn.pendingSpineTurn?.animated, false)
        XCTAssertTrue(installed.superview === view)
        XCTAssertEqual(view.turn.turnOverlays.count, 1)
        XCTAssertEqual(web.alphaValue, 0)

        let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            delegate.moveCount > moves && web.alphaValue == 1 && view.turn.turnOverlays.isEmpty
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.currentSpineIndex, publication.readingOrder.count - 1)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertNil(installed.superview)
        XCTAssertTrue(delegate.failures.isEmpty)
    }
}
