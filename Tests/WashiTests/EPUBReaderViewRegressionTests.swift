import AppKit
import WebKit
import XCTest
@testable import Washi

// EPUBReaderView の回帰: 読み込み方針・読み込み中の移動先・設定の反映・ドロップ。
// 見開きの setup は ReaderViewSpreadSetupTests、テキストアンカーは
// ReaderViewTextAnchorLandingTests、census は ReaderViewCensusTests、キー転送は
// ReaderViewKeyForwardingTests、WebContent の再読み込みは WebContentReloadTests に分けた

@MainActor
final class EPUBReaderViewRegressionTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBFixtures.verticalNovel(name: "washi-reader-regression")
    }

    private static func documentToken(fromOptionsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["documentToken"] as? String
    }

    // MARK: - 読み込み方針(SpineNavigationGate)

    /// meta refresh などの .other は期待外なら reader 経由へ戻し、直前に
    /// 記録した loadSpineItem 自身の .other は一度だけ通す
    func testUnexpectedOtherNavigationRoutesWithoutConsumingExpectedLoad() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml", generation: 1)
        XCTAssertEqual(
            gate.disposition(
                for: "OEBPS/text/ch1.xhtml", navigationType: .linkActivated),
            .routeThroughReader)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch2.xhtml", navigationType: .other),
            .routeThroughReader)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .allowExpectedLoad)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .routeThroughReader)
    }

    /// 高速な spine 移動で decide が前後しても、自分が発行した各ロードを
    /// 文書内遷移と誤認しない
    func testCompetingExpectedSpineLoadsAreBothAllowed() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml", generation: 1)
        gate.expect("OEBPS/text/ch2.xhtml", generation: 2)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .allowExpectedLoad)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch2.xhtml", navigationType: .other),
            .allowExpectedLoad)
    }

    // MARK: - 読み込み失敗の分類

    /// 102 のうち、文書の遷移を policy で拒否したものだけを無通知で畳む。
    /// 現在の読み込みに対応する 102 と他の失敗は通知対象に残す。
    func testNavigationFailureClassificationDoesNotSuppressCurrentLoad102() {
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        XCTAssertTrue(EPUBReaderView.isExpectedNavigationCancellation(
            interrupted, hasNavigation: false))
        XCTAssertFalse(EPUBReaderView.isExpectedNavigationCancellation(
            interrupted, hasNavigation: true))
        for hasNavigation in [false, true] {
            XCTAssertTrue(EPUBReaderView.isExpectedNavigationCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
                hasNavigation: hasNavigation))
            XCTAssertFalse(EPUBReaderView.isExpectedNavigationCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData),
                hasNavigation: hasNavigation))
            XCTAssertFalse(EPUBReaderView.isExpectedNavigationCancellation(
                NSError(domain: "別ドメイン", code: 102), hasNavigation: hasNavigation))
        }

        let view = EPUBReaderView(frame: .zero)
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let cover = NSImageView(frame: .zero)
        view.installTurnCover(cover, pending: true)
        view.handleNavigationFailure(interrupted, hasNavigation: false)
        XCTAssertTrue(delegate.failures.isEmpty)
        XCTAssertNotNil(view.turn.pendingSpineTurn)

        view.handleNavigationFailure(interrupted, hasNavigation: true)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual((delegate.failures.first as? NSError)?.code, 102)
        XCTAssertNil(view.turn.pendingSpineTurn)
        XCTAssertNil(cover.superview)
    }

    /// 解決後の fallback が未対応・欠落なら、状態変更前の判定 spineLoadFailure が
    /// 失敗理由を返す。正規化された XHTML と実在する画像 fallback は受理する。
    /// 通知と拒否は SpineLoadFailureRecoveryTests で確かめる。
    func testUnrenderableSpineFallbackIsClassifiedAsLoadFailure() throws {
        for (mediaType, exists, renderable) in [
            ("image/psd", true, false),
            ("application/xhtml+xml", false, false),
            (" Application/XHTML+XML; charset=UTF-8 ", true, true),
            ("image/png", true, true),
        ] {
            var entries = EPUBFixtures.singleSpineEntries(bodyHTML: "<p>本文</p>")
            entries = try EPUBFixtures.replacing(
                entries, in: "OEBPS/package.opf",
                of: #"<item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/>"#,
                with: """
                    <item id="c" href="foreign.dmg" media-type="application/octet-stream" fallback="fb"/>
                    <item id="fb" href="fallback" media-type="\(mediaType)"/>
                    """)
            entries.append(("OEBPS/foreign.dmg", Data([0])))
            if exists { entries.append(("OEBPS/fallback", Data([1]))) }
            let publication = try EPUBPublication(
                data: ZipBuilder.build(entries),
                displayURL: URL(fileURLWithPath: "/tmp/unrenderable-fallback.epub"))
            let entry = publication.readingOrder[0]
            XCTAssertEqual(publication.canRenderSpineResource(entry), renderable)
            // 状態を変える前に使う判定なので、通知ではなく失敗理由を直接確かめる。
            let failure = EPUBReaderView.spineLoadFailure(
                entry, in: publication, url: URL(string: "washi-epub://test/fallback"))
            XCTAssertEqual(failure == nil, renderable)
            if !renderable {
                XCTAssertTrue(String(describing: try XCTUnwrap(failure)).contains("no renderable fallback"))
            }
        }
    }

    // MARK: - 読み込み中の移動先

    /// JS へ復元先を適用した直後、最初の pageChanged より前に保存位置を
    /// 読んでも progression を失わない
    func testRestoreLocatorSurvivesSetupTargetApplication() throws {
        let publication = try makePublication()
        let locator = publication.locator(forSpineIndex: 1, progression: 0.625)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication, at: locator)

        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.625, accuracy: 0.0001)
    }

    /// cooViewer-oxr.19: 読み込み中の同一 spine go は旧 DOM へ送らず、
    /// 最後に指定された target を setup が消費する。
    func testSameSpineGoDuringLoadUsesNewestPendingTarget() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 1, progression: 0.2))

        view.go(to: publication.locator(
            forSpineIndex: 1, progression: 0.75))
        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.75, accuracy: 0.0001)
    }

    /// cooViewer-oxr.19: TOC と同一文書 href も読み込み中は共通の
    /// pendingTarget 経路を通る。
    func testSameSpineTOCAndContainerNavigationQueueDuringLoad() throws {
        let publication = try makePublication()
        let tocView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        tocView.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 0, progression: 0.6))
        tocView.go(to: try XCTUnwrap(publication.navigation.toc.first))
        XCTAssertEqual(tocView.currentLocator.progression, 0, accuracy: 0.0001)

        let hrefView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        hrefView.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 0, progression: 0.6))
        hrefView.goToContainerPath(
            publication.readingOrder[0].resolvedContainerPath, fragment: nil)
        XCTAssertEqual(hrefView.currentLocator.progression, 0, accuracy: 0.0001)
    }

    /// cooViewer-oxr.23: .end を適用して pageChanged が届く前も、保存位置を
    /// 章頭の 0 に潰さない。
    func testCurrentLocatorKeepsEndTargetBeforePageChanged() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        view.goToBookEnd()

        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex,
                       publication.readingOrder.count - 1)
        XCTAssertEqual(view.currentLocator.progression, 1, accuracy: 0.0001)
    }

    /// cooViewer-oxr.19/23: 旧文書の遅配 pageChanged は読み込み先の
    /// pending locator を消さず、ホストへも移動通知しない。
    func testPageChangedFromOldDocumentIsIgnoredDuringLoad() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        view.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 1, progression: 0.75))

        view.handleScriptMessage([
            "type": "pageChanged", "page": 5, "pageCount": 10,
            "pagesPerScreen": 1,
        ])

        XCTAssertEqual(view.pageInItem, 0)
        XCTAssertEqual(view.currentLocator.progression, 0.75, accuracy: 0.0001)
        XCTAssertEqual(delegate.moveCount, 0)
    }

    // MARK: - 設定と表示の反映

    /// cooViewer-oxr.20: 画像ページの実測 1 面ではなく、画面計画 2 面を
    /// 基準に columnMode を反転する。
    func testToggleColumnModeUsesPlannedPagesForImageItem() throws {
        let publication = try EPUBFixtures.publication(
            EPUBFixtures.imagePageEntries(bodyHTML: "<img src=\"../images/page.png\"/>"),
            name: "washi-toggle-image")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        var settings = view.settings
        settings.columnMode = .double
        view.settings = settings
        view.load(publication: publication)

        XCTAssertEqual(view.pagesPerScreen, 1)
        XCTAssertEqual(view.plannedPagesPerScreen, 2)
        view.toggleColumnMode()
        XCTAssertEqual(view.settings.columnMode, .single)
        view.toggleColumnMode()
        XCTAssertEqual(view.settings.columnMode, .double)
    }

    /// cooViewer-t4e: ホストが足したオーバーレイは load による webView
    /// 再構築後も webView より前面に残る
    func testHostOverlayRemainsAboveWebViewAcrossReload() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)

        let overlay = NSView(frame: view.bounds)
        view.addSubview(overlay)
        view.load(publication: publication)

        let rebuiltWebView = try XCTUnwrap(
            view.subviews.firstIndex(where: { $0 is WKWebView }))
        let overlayIndex = try XCTUnwrap(view.subviews.firstIndex(of: overlay))
        XCTAssertLessThan(rebuiltWebView, overlayIndex)
    }

    /// cooViewer-oxr.24: userCSS は色だけの差し替えでなく導出レイアウトキーを
    /// 変え、現在 spine の pageCount を再計測する。
    func testUserCSSChangeRepaginatesCurrentItem() async throws {
        let body = (1...36).map { "<p>段落 \($0) 本文本文本文本文本文</p>" }
            .joined()
        let publication = try EPUBFixtures.singleSpine(bodyHTML: body,
            name: "washi-user-css-layout")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = view.settings
        settings.columnMode = .single
        view.settings = settings
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        view.load(publication: publication)

        let didFinishInitialSetup = await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) { delegate.moveCount > 0 }
        guard didFinishInitialSetup else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let originalCount = view.pageCountInItem
        var updated = view.settings
        updated.userCSS = """
            p { break-before: column !important;
                -webkit-column-break-before: always !important; }
            """
        view.settings = updated

        let didRepaginate = await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) { view.pageCountInItem > originalCount }
        XCTAssertTrue(didRepaginate)
    }

    /// cooViewer-oxr.24: setup 後に handlesKeyboardNavigation を false へ
    /// 切り替えた文書は、次の keydown を delegate へ送る。
    func testKeyboardSettingChangeUpdatesLoadedScript() async throws {
        let publication = try EPUBFixtures.reflowSpread(.none)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        view.load(publication: publication)
        let didFinishInitialSetup = await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) { delegate.moveCount > 0 }
        guard didFinishInitialSetup else {
            return try failOrSkipIfWebKitUnavailable()
        }

        var updated = view.settings
        updated.handlesKeyboardNavigation = false
        view.settings = updated
        let webView = try view.firstWebView()
        let dispatched = try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                """
                document.dispatchEvent(new KeyboardEvent('keydown', {
                    key:'x', code:'KeyX', bubbles:true
                }));
                return true;
                """,
                in: nil, contentWorld: WashiContentWorld.world)
            return result as? Bool ?? false
        }.value
        XCTAssertTrue(dispatched)

        let didForward = await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) { delegate.keys.count == 1 }
        XCTAssertTrue(didForward)
        XCTAssertEqual(delegate.keys.first?.key, "x")
    }

    /// cooViewer-oxr.48: JS setup の機能検出結果を公開プロパティへ写し、
    /// 縦見開きの単ページ fallback を保持する。
    func testSetupResultPublishesUnsupportedColumnAxisFallback() {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        var settings = view.settings
        settings.columnMode = .double
        view.settings = settings

        view.applySetupResult([
            "pageCount": 8,
            "pagesPerScreen": 1,
            "imagePage": false,
            "mode": "vrl",
            "supportsColumnAxis": false,
        ])

        XCTAssertFalse(view.columnAxisSupported)
        XCTAssertEqual(view.pagesPerScreen, 1)
    }

    /// cooViewer-oxr.54: hidden view の frame 変更は census を起動せず、
    /// unhide で一度だけ延期レイアウトを消費する。
    func testHiddenLayoutDefersCensusUntilUnhide() throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-hidden-layout")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        view.load(publication: publication)
        view.cancelPageCensus()

        view.isHidden = true
        view.frame.size.width = 1_000
        view.layout()
        XCTAssertTrue(view.hasDeferredVisibleLayout)
        XCTAssertFalse(view.isPageCensusScheduled)

        view.isHidden = false
        XCTAssertFalse(view.hasDeferredVisibleLayout)
        XCTAssertTrue(view.isPageCensusScheduled)
    }

    /// cooViewer-oxr.54: 表示中に予約済みの再ページ割りも、hide 後に
    /// 起床して不可視 WebView を更新しない。
    func testHideCancelsAlreadyScheduledRepagination() async throws {
        let publication = try EPUBFixtures.reflowSpread(.none)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        view.load(publication: publication)
        guard await waitUntil(timeout: .seconds(5), poll: .milliseconds(20), { delegate.moveCount > 0 }) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        // 最初の表示は描画フレームを待ってから戻り、その間は setup 中の扱いになる。
        // 表示が戻る(setup が終わる)まで待ってから設定を変える
        let web = try view.firstWebView()
        let didRestoreDisplay = await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) { web.alphaValue == 1 }
        XCTAssertTrue(didRestoreDisplay)

        var updated = view.settings
        updated.userCSS = "body { line-height: 1.8; }"
        view.settings = updated
        XCTAssertTrue(view.isRepaginationScheduled)

        view.isHidden = true
        XCTAssertFalse(view.isRepaginationScheduled)
        XCTAssertTrue(view.hasDeferredVisibleLayout)
    }

    /// cooViewer-oxr.46 C35: setup で渡す文書の印で、差し替え前の文書から
    /// 遅れて届いた通知を判別する。印が無い通知は従来どおり受け入れる。
    func testSetupCarriesDocumentTokenAndStaleTokensAreRejected() throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let book = try makePublication()
        view.load(publication: book)
        let token = try XCTUnwrap(
            Self.documentToken(fromOptionsJSON: view.setupOptionsJSON()),
            "setup に文書の印が入っていない")
        XCTAssertFalse(token.isEmpty)

        XCTAssertTrue(view.isFromCurrentDocument(["token": token]))
        XCTAssertFalse(view.isFromCurrentDocument(["token": token + "-old"]))
        // 印を持たない通知(ラスタライザ経路・古い注入)は受け入れる
        XCTAssertTrue(view.isFromCurrentDocument([:]))
    }

    // MARK: - ドロップ

    /// cooViewer-oxr.84: URL pasteboard が http URL を返しても、ファイル drop の
    /// delegate 契約へは流さない。
    func testDroppedHTTPURLIsRejectedBeforeDelegateDispatch() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "org.cocoadialog.WashiTests.drop.\(UUID().uuidString)"))
        pasteboard.declareTypes([.URL], owner: nil)
        let remoteURL = try XCTUnwrap(
            URL(string: "https://example.invalid/book.epub"))
        let wroteURL = pasteboard.setString(remoteURL.absoluteString, forType: .URL)

        if wroteURL {
            XCTAssertFalse(view.dispatchDroppedURL(from: pasteboard))
        } else {
            // cooViewer-oxr.84: sandbox で pasteboard service が使えない場合も
            // URL gate 自体は検証する。
            XCTAssertFalse(view.dispatchDroppedURL(remoteURL))
        }
        XCTAssertTrue(delegate.droppedURLs.isEmpty)
        XCTAssertTrue(view.dispatchDroppedURL(
            URL(fileURLWithPath: "/tmp/local.epub")))
        XCTAssertEqual(delegate.droppedURLs,
                       [URL(fileURLWithPath: "/tmp/local.epub")])
    }
}
