import AppKit
import WebKit
import XCTest
@testable import Washi

// spine 遷移の見え方の取り決め:
// 1. 読み込みの開始では透明にしない(前のページはコミットまで見えている)
// 2. 描画フレームの待ちは必ず打ち切られ、取り消しにも即座に応じる
// 3. 控えのカバーは条件が一致したときだけ、撮った矩形に貼られ、表示が戻ると畳まれる
// 4. 見た目の変更と画面への復帰で控えを撮り直す
// 5. 続けて移動したときは、最初に重ねた前のページの控えを最新の項目の表示まで使う

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
final class SpineTransitionAppearanceTests: XCTestCase {
    private func makePublication(_ name: String = "washi-spine-transition") throws
        -> EPUBPublication
    {
        try EPUBFixtures.verticalNovel(name: name)
    }

    /// 2 番目の項目(ch2)を text/html と宣言し、描画可能な fallback の無い項目にする
    private func makePublicationWithUnrenderableSecondItem() throws -> EPUBPublication {
        var entries = EPUBFixtures.verticalNovelEntries()
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: #"<item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>"#,
            with: #"<item id="ch2" href="text/ch2.xhtml" media-type="text/html"/>"#)
        let publication = try EPUBFixtures.publication(entries, name: "washi-unrenderable-second")
        XCTAssertFalse(publication.canRenderSpineResource(publication.readingOrder[1]))
        return publication
    }

    /// 本を開き、最初の表示が戻るまで待つ。WebKit が使えなければ skip する
    private func openAndSettle(_ view: EPUBReaderView, _ publication: EPUBPublication,
                               delegate: ReaderObservationSpy) async throws {
        view.delegate = delegate
        view.load(publication: publication)
        guard await waitUntil(timeout: .seconds(8), poll: .milliseconds(5), { delegate.moveCount > 0 }) else {
            return try skipOrFailIfWebKitUnavailable()
        }
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { (try? view.firstWebView().alphaValue) == 1 }
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

    private func makeCoverReader(theme: EPUBReaderTheme = .light,
                                 pageTurnStyle: EPUBPageTurnStyle = .none)
        -> (view: EPUBReaderView, window: NSWindow)
    {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.settings.theme = theme
        view.settings.pageTurnStyle = pageTurnStyle
        view.accessibilityReduceMotionOverride = false
        view.accessibilityIncreaseContrastOverride = false
        view.accessibilityDifferentiateWithoutColorOverride = false
        view.isWindowOnScreenOverride = true
        // 画面外でも、見た目を変えた JS の実行後に撮影する順序を保つ
        view.animationFrameWait = {
            await EPUBReaderView.waitForWashiScript("return true;", in: $0)
        }
        return (view, makeOffscreenWindow(containing: view))
    }

    /// 控えの引き継ぎを確かめるリーダー。画面外扱いに固定して撮影を止め、控えは
    /// 差し替え口で置く。アクセシビリティの設定も固定し、OS の設定に依存させない
    private func makeChainReader(reduceMotion: Bool = false,
                                 pageTurnStyle: EPUBPageTurnStyle = .none)
        -> (view: EPUBReaderView, window: NSWindow)
    {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.settings.pageTurnStyle = pageTurnStyle
        view.accessibilityReduceMotionOverride = reduceMotion
        view.accessibilityIncreaseContrastOverride = false
        view.accessibilityDifferentiateWithoutColorOverride = false
        view.isWindowOnScreenOverride = false
        return (view, makeOffscreenWindow(containing: view))
    }

    private func waitForCover(
        _ view: EPUBReaderView, replacing old: NSImage? = nil,
        message: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> EPUBReaderView.PrefetchedPageCover {
        let ready = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            guard let cover = view.pageCover.prefetchedPageCover else { return false }
            return cover.image !== old
        }
        return try XCTUnwrap(
            ready ? view.pageCover.prefetchedPageCover : nil,
            message ?? (old == nil
                ? "初回の控え A を撮影できない。画面外のウインドウで撮影できる前提を確認する"
                : "控えの撮り直しが時間切れになった"),
            file: file, line: line)
    }

    /// スクロール補正の遅配を待ち、移動回数と控えの同一性が 300 ms 続けて安定したら返す。
    private func settledCover(_ view: EPUBReaderView, delegate: ReaderObservationSpy) async throws
        -> EPUBReaderView.PrefetchedPageCover
    {
        var current = try await waitForCover(view)
        var moves = delegate.moveCount
        var stableSince = ContinuousClock.now
        let settled = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            guard let cover = view.pageCover.prefetchedPageCover else {
                stableSince = .now
                return false
            }
            if delegate.moveCount != moves || cover.image !== current.image {
                moves = delegate.moveCount
                current = cover
                stableSince = .now
            }
            return ContinuousClock.now - stableSince >= .milliseconds(300)
        }
        return try XCTUnwrap(settled ? view.pageCover.prefetchedPageCover : nil,
                             "移動回数と控えが安定するまでの待ちが時間切れになった")
    }

    /// sRGB の 16×16 画素に縮小し、本文より広い地色の明るさを調べる
    private func meanLuminance(_ image: NSImage) -> Double {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8,
                bytesPerRow: 16 * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else {
            XCTFail("控えの輝度を調べるための画像と描画領域を用意できない")
            return .nan
        }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let total = stride(from: 0, to: 16 * 16 * 4, by: 4).reduce(0.0) { sum, offset in
            sum + 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
        }
        return total / (16 * 16 * 255)
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
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var settings = view.settings
        settings.pageTurnStyle = .none
        view.settings = settings
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
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

    /// 演出ありの送り(既定の slide)では控えを使わない
    func testCoverIsNotUsedWithAnimatedPageTurns() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // CI ランナーには視差効果を減らす設定が有効なものがあるので、OS 設定に依存させない
        view.accessibilityReduceMotionOverride = false
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
        XCTAssertEqual(view.settings.pageTurnStyle, .slide)
        view.setPrefetchedPageCoverForTesting(cover(
            for: view, rect: view.bounds,
            spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem))
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertNil(view.pageCover.armedSpineCover)
    }

    /// 視差効果を減らす設定では演出が省かれるので、slide でも控えを使う
    func testCoverIsUsedWithAnimatedPageTurnsWhenReducingMotion() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibilityReduceMotionOverride = true
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
        XCTAssertEqual(view.settings.pageTurnStyle, .slide)
        let prepared = cover(for: view, rect: view.bounds,
                             spineIndex: view.currentSpineIndex, pageInItem: view.pageInItem)
        view.setPrefetchedPageCoverForTesting(prepared)
        view.go(to: EPUBLocator(spineIndex: 1, progression: 0))
        XCTAssertTrue(view.pageCover.armedSpineCover?.image === prepared.image)
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
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var settings = view.settings
        settings.pageTurnStyle = .none
        view.settings = settings
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        try await openAndSettle(view, publication, delegate: ReaderObservationSpy())
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
