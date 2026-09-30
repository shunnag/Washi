import AppKit
import WebKit
import XCTest
@testable import Washi

// 控えのカバーの撮り直しと使いどころ。取り決めの全体は PageCoverTestSupport.swift を参照

/// 次の章のナビゲーション許可を保留し、コミット前の旧文書を確実に観測する。
@MainActor
private final class HeldChapterNavigation: NSObject, WKNavigationDelegate {
    private let reader: EPUBReaderView
    private var continuation: CheckedContinuation<WKNavigationActionPolicy, Never>?
    var isWaiting: Bool { continuation != nil }

    init(reader: EPUBReaderView) {
        self.reader = reader
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let (policy, preferences) = await reader.webView(
            webView, decidePolicyFor: navigationAction, preferences: preferences)
        guard policy == .allow, navigationAction.targetFrame?.isMainFrame == true else {
            return (policy, preferences)
        }
        let releasedPolicy = await withCheckedContinuation { continuation = $0 }
        return (releasedPolicy, preferences)
    }

    func finish(in webView: WKWebView, policy: WKNavigationActionPolicy) {
        // 許可を返す前に戻し、didCommit・didFinish は実際のリーダーに任せる。
        webView.navigationDelegate = reader
        let pending = continuation
        continuation = nil
        pending?.resume(returning: policy)
    }
}

@MainActor
final class PageCoverRetakeTests: XCTestCase {
    private func makePublication(_ name: String = "washi-spine-transition") throws
        -> EPUBPublication
    {
        try EPUBFixtures.verticalNovel(name: name)
    }

    // MARK: - 控えのカバー

    func testThemeChangeRetakesTheCoverInTheNewColors() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let initial = try await waitForCover(view)
        XCTAssertGreaterThan(meanLuminance(initial.image), 0.6, "初回の控えは明るい配色で撮る")

        view.settings.theme = .dark
        XCTAssertNil(view.pageCover.prefetchedPageCover, "古い配色の控えはその場で捨てる")
        let updated = try await waitForCover(view, replacing: initial.image)
        XCTAssertLessThan(meanLuminance(updated.image), 0.4, "撮り直した控えは暗い配色を反映する")

        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === updated.image, "新しい配色の控えを取り置く")
    }

    func testAppearanceOnlyChangesRetakeTheCover() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        var current = try await waitForCover(view)
        let stages: [(name: String, dropsCover: Bool, change: @MainActor () -> Void)] = [
            ("コントラストの強調", true, { view.accessibilityIncreaseContrastOverride = true }),
            ("外観の変更", true, { view.viewDidChangeEffectiveAppearance() }),
            ("ハイライトの追加", false, {
                view.highlights = [EPUBHighlight(
                    id: "h", spineIndex: 0, utf16Offset: 0, utf16Length: 2)]
            }),
            ("ハイライトの削除", false, { view.highlights = [] }),
        ]
        for (stage, dropsCover, change) in stages {
            let old = current
            change()
            if dropsCover {
                XCTAssertNil(view.pageCover.prefetchedPageCover, "\(stage): 古い見た目の控えはその場で捨てる")
            } else {
                XCTAssertTrue(view.pageCover.prefetchedPageCover?.image === old.image,
                              "\(stage): 撮り直すまで前の控えを残す")
            }
            current = try await waitForCover(
                view, replacing: old.image, message: "\(stage): 控えの撮り直しが時間切れになった")
        }

        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === current.image, "最後に撮り直した控えを取り置く")
    }

    func testHighlightOnAnotherItemKeepsTheCoverForTheNextMove() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let a = try await waitForCover(view)

        view.highlights = [EPUBHighlight(
            id: "h", spineIndex: 1, utf16Offset: 0, utf16Length: 2)]
        XCTAssertTrue(view.pageCover.prefetchedPageCover?.image === a.image,
                      "別の章のハイライトを設定しても現在の控えを残す")
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === a.image,
                      "検索の例のように別の章のハイライトを設定してすぐ移動しても控えを使う")
    }

    func testNarrationHighlightRetakesTheCoverWithoutDroppingIt() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, try makePublication(), delegate: delegate)
        var current = try await settledCover(view, delegate: delegate)
        let moves = delegate.moveCount
        let stages: [(name: String, fragmentID: String?)] = [
            ("区間の読み上げハイライト", "sec1"), ("読み上げハイライトの解除", nil),
        ]

        for (stage, fragmentID) in stages {
            let old = current
            view.mediaOverlayHighlight(fragmentID: fragmentID,
                                       cssClass: EPUBReaderView.defaultActiveClass)
            XCTAssertTrue(view.pageCover.prefetchedPageCover?.image === old.image,
                          "\(stage): 撮り直すまで前の控えを残す")
            current = try await waitForCover(
                view, replacing: old.image,
                message: "\(stage): 読み上げハイライトを控えに写していない")
        }

        XCTAssertEqual(delegate.moveCount, moves, "ページを送らずに控えだけを撮り直す")
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === current.image, "最後に撮り直した控えを取り置く")
    }

    func testChapterAdvanceBeforeTheRetakeKeepsThePreviousCover() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let a = try await waitForCover(view)

        view.mediaOverlayHighlight(fragmentID: "sec1", cssClass: EPUBReaderView.defaultActiveClass)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === a.image,
                      "撮り直しが章送りに間に合わなくても、前の控えを取り置く")
    }

    func testChapterLoadKeepsTheOldNarrationHighlightAndAppliesTheNewOne() async throws {
        var entries = EPUBFixtures.verticalNovelEntries()
        // 次の章の最初の区間に断片 ID を付ける
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/text/ch2.xhtml", of: "<h1>", with: "<h1 id=\"sec2\">")
        let publication = try EPUBFixtures.publication(entries,
            name: "washi-narration-chapter-load")
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        let delegate = ReaderObservationSpy()
        try await openAndSettle(view, publication, delegate: delegate)
        let web = try view.firstWebView()
        let cssClass = "test-narration-active"
        // 旧文書の準備は JS の完了まで待ち、Swift 側の送信タイミングに依存させない。
        let highlighted = try await view.evaluateForTest("""
            __washi.mediaOverlayHighlight('sec1', '\(cssClass)');
            return document.getElementById('sec1').classList.contains('\(cssClass)');
            """) as? Bool
        XCTAssertEqual(highlighted, true)

        let gate = HeldChapterNavigation(reader: view)
        web.navigationDelegate = gate
        defer { gate.finish(in: web, policy: .cancel) }
        // コントローラと同じく、章送り直後に次の章の最初の区間を強調する。
        view.navigateForMediaOverlay(toSpineIndex: 1)
        view.mediaOverlayHighlight(fragmentID: "sec2", cssClass: cssClass)
        let held = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { gate.isWaiting }
        XCTAssertTrue(held, "新文書のコミット前に読み込みを保留する")
        let oldHighlightRemains = try await view.evaluateForTest("""
            return document.getElementById('sec2') === null
                && document.getElementById('sec1').classList.contains('\(cssClass)');
            """) as? Bool
        XCTAssertEqual(oldHighlightRemains, true, "読み込み中は旧文書の読み上げハイライトを消さない")

        gate.finish(in: web, policy: .allow)
        let newCover = try await waitForCover(view)
        XCTAssertEqual(newCover.spineIndex, 1)
        let newHighlightApplied = try await view.evaluateForTest("""
            return document.getElementById('sec2').classList.contains('\(cssClass)');
            """) as? Bool
        XCTAssertEqual(newHighlightApplied, true, "setup 後に新しい章の最初の区間を強調する")
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testBackingScaleChangeRetakesTheCover() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let a = try await waitForCover(view)
        view.setPrefetchedPageCoverForTesting(EPUBReaderView.PrefetchedPageCover(
            image: a.image, rect: a.rect,
            backingScale: window.backingScaleFactor == 1 ? 2 : 1,
            spineIndex: a.spineIndex, pageInItem: a.pageInItem,
            size: a.size, fontScale: a.fontScale))

        view.viewDidChangeBackingProperties()
        XCTAssertNil(view.pageCover.prefetchedPageCover, "倍率の違う控えはその場で捨てる")
        let b = try await waitForCover(view, replacing: a.image)
        XCTAssertEqual(b.backingScale, window.backingScaleFactor)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === b.image, "新しい倍率の控えを取り置く")
    }

    func testSameBackingScaleKeepsTheCover() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .unload) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let a = try await waitForCover(view)

        view.viewDidChangeBackingProperties()
        XCTAssertTrue(view.pageCover.prefetchedPageCover?.image === a.image, "倍率が同じなら控えを残す")
    }

    func testNonAppearanceSettingKeepsTheCover() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let a = try await waitForCover(view)

        view.settings.handlesKeyboardNavigation.toggle()
        XCTAssertTrue(view.pageCover.prefetchedPageCover?.image === a.image,
                      "キー操作の設定を変えても現在の控えを残す")
    }

    func testLayoutAndThemeChangeDoesNotUseTheOldCover() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        let initial = try await waitForCover(view)

        var settings = view.settings
        settings.theme = .dark
        settings.lineHeightScale = 1.8
        view.settings = settings
        XCTAssertNil(view.pageCover.prefetchedPageCover, "配色と組版を一緒に変えても古い控えはその場で捨てる")
        let updated = try await waitForCover(view, replacing: initial.image)
        XCTAssertLessThan(meanLuminance(updated.image), 0.4, "組版後の控えは暗い配色を反映する")
    }

    func testCoverIsRetakenWhenTheWindowIsVisibleAgain() async throws {
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        var current = try await waitForCover(view)
        for notification in [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didDeminiaturizeNotification] {
            let old = current
            view.isWindowOnScreenOverride = false
            NotificationCenter.default.post(
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            XCTAssertNil(view.pageCover.prefetchedPageCover, "\(notification.rawValue): 画面外では控えを捨てる")

            view.isWindowOnScreenOverride = true
            NotificationCenter.default.post(name: notification, object: window)
            current = try await waitForCover(
                view, replacing: old.image,
                message: "\(notification.rawValue): 画面への復帰後の撮り直しが時間切れになった")
        }

        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === current.image, "画面に戻った後の控えを取り置く")
    }

    func testFixedLayoutCoverIsRetakenWhenTheViewIsShownAgain() async throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-cover-fxl")
        let (view, window) = makeCoverReader()
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
        let initial = try await waitForCover(view)

        view.isHidden = true
        XCTAssertNil(view.pageCover.prefetchedPageCover, "固定レイアウトでも隠すときに控えを捨てる")
        view.isHidden = false
        let updated = try await waitForCover(view, replacing: initial.image)

        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === updated.image, "再表示後の固定レイアウトの控えを取り置く")
    }

    func testSwitchingOffPageTurnAnimationTakesTheCover() async throws {
        let (view, window) = makeCoverReader(pageTurnStyle: .slide)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, try makePublication(), delegate: ReaderObservationSpy())
        // setup の撮影予約が設定変更後に走ると、修正前でも控えができてしまう。
        // 既存の差し替え口で目印を置き、演出ありの撮影処理が捨てるまで待つ。
        view.setPrefetchedPageCoverForTesting(cover(for: view, rect: view.bounds))
        view.schedulePageCoverPrefetch()
        let cleared = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { view.pageCover.prefetchedPageCover == nil }
        XCTAssertTrue(cleared, "演出ありの撮影処理が控えを捨てて完了する")
        XCTAssertNil(view.pageCover.prefetchedPageCover, "演出ありの送りでは控えを撮らない")

        view.settings.pageTurnStyle = .none
        _ = try await waitForCover(view, message: "演出を無効にした後の控えの撮影が時間切れになった")
    }

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

    /// コミット待ちの控えは、読み込み先の項目とページ番号を使わずに表示条件を照合する
    func testPrefetchedCoverMatchesTheDisplayRegardlessOfTheItem() {
        let base = EPUBReaderView.PrefetchedPageCover(
            image: NSImage(), rect: .zero, backingScale: 2, spineIndex: 3,
            pageInItem: 4, size: NSSize(width: 800, height: 600), fontScale: 1)
        let size = NSSize(width: 800, height: 600)
        XCTAssertFalse(base.matches(spineIndex: 2, pageInItem: 4, size: size,
                                    fontScale: 1, backingScale: 2))
        XCTAssertFalse(base.matches(spineIndex: 3, pageInItem: 5, size: size,
                                    fontScale: 1, backingScale: 2))
        XCTAssertTrue(base.matchesDisplay(size: size, fontScale: 1, backingScale: 2))
        XCTAssertFalse(base.matchesDisplay(size: NSSize(width: 801, height: 600),
                                           fontScale: 1, backingScale: 2), "size")
        XCTAssertFalse(base.matchesDisplay(size: size, fontScale: 1.1,
                                           backingScale: 2), "font scale")
        XCTAssertFalse(base.matchesDisplay(size: size, fontScale: 1,
                                           backingScale: 1), "backing scale")
    }

    /// 用意された控えは didCommit で撮った矩形に貼られ、表示が戻ると畳まれる
    func testPreparedCoverIsInstalledAtCommitAndFoldedAfterDisplay() async throws {
        let publication = try makePublication()
        try await withSettledReader(publication: publication, configure: { view in
            var settings = view.settings
            settings.pageTurnStyle = .none
            view.settings = settings
        }) { view, _ in
            // カバーが見えている間を確実に観測できるよう、表示の復帰を打ち切りまで遅らせる
            view.animationFrameWait = { _ in try? await Task.sleep(for: .seconds(30)) }
            view.animationFrameWaitTimeout = .milliseconds(400)
            let rect = NSRect(x: 12, y: 34, width: 200, height: 150)
            let prepared = cover(for: view, rect: rect,
                                 spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
            view.setPrefetchedPageCoverForTesting(prepared)

            view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
            XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image, "離れるページの控えを取り置く")
            let installed = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
                view.turn.pendingSpineTurn?.cover.image === prepared.image
            }
            XCTAssertTrue(installed, "didCommit でカバーとして貼られる")
            let cover = try XCTUnwrap(view.turn.pendingSpineTurn?.cover)
            XCTAssertEqual(cover.frame, rect, "撮った矩形に置く")
            XCTAssertTrue(view.turn.turnOverlays.contains { $0 === cover })
            XCTAssertEqual(try view.firstWebView().alphaValue, 0)

            let folded = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
                (try? view.firstWebView().alphaValue) == 1 && view.turn.turnOverlays.isEmpty
            }
            XCTAssertTrue(folded, "表示が戻ったらカバーを畳む")
            XCTAssertNil(view.turn.pendingSpineTurn)
        }
    }

    /// 演出ありの送り(既定の slide)では控えを使わない
    func testCoverIsNotUsedWithAnimatedPageTurns() async throws {
        let publication = try makePublication()
        try await withSettledReader(publication: publication, configure: { view in
            // CI ランナーには視差効果を減らす設定が有効なものがあるので、OS 設定に依存させない
            view.accessibilityReduceMotionOverride = false
        }) { view, _ in
            XCTAssertEqual(view.settings.pageTurnStyle, .slide)
            view.setPrefetchedPageCoverForTesting(cover(
                for: view, rect: view.bounds,
                spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem))
            view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
            XCTAssertNil(view.pageCover.armedSpineCover)
        }
    }

    /// 視差効果を減らす設定では演出が省かれるので、slide でも控えを使う
    func testCoverIsUsedWithAnimatedPageTurnsWhenReducingMotion() async throws {
        let publication = try makePublication()
        try await withSettledReader(publication: publication, configure: { view in
            view.accessibilityReduceMotionOverride = true
        }) { view, _ in
            XCTAssertEqual(view.settings.pageTurnStyle, .slide)
            let prepared = cover(for: view, rect: view.bounds,
                                 spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
            view.setPrefetchedPageCoverForTesting(prepared)
            view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
            XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image)
        }
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
        XCTAssertNil(view.pageCover.prefetchedPageCover)
        XCTAssertNil(view.pageCover.armedSpineCover)

        view.setPrefetchedPageCoverForTesting(cover(for: view, rect: view.bounds))
        view.unload()
        XCTAssertNil(view.pageCover.prefetchedPageCover)
        XCTAssertNil(view.pageCover.armedSpineCover)
    }

    /// 控えが無い遷移はカバー無しで最後まで進む
    func testTransitionWithoutAPrefetchedCoverFallsBack() async throws {
        let publication = try makePublication()
        try await withSettledReader(publication: publication, configure: { view in
            var settings = view.settings
            settings.pageTurnStyle = .none
            view.settings = settings
        }) { view, _ in
            XCTAssertGreaterThan(publication.readingOrder.count, 2)
            view.setPrefetchedPageCoverForTesting(nil)
            view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
            view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
            XCTAssertNil(view.pageCover.armedSpineCover)
            XCTAssertNil(view.pageCover.prefetchedPageCover)
            let restored = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
                (try? view.firstWebView().alphaValue) == 1 && view.turn.turnOverlays.isEmpty
            }
            XCTAssertTrue(restored)
            XCTAssertNil(view.turn.pendingSpineTurn)
        }
    }
}
