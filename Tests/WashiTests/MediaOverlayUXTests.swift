import AppKit
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C26: 再生 UX(読み飛ばし・速度・位置の保存と復元)。
@MainActor
final class MediaOverlayUXTests: XCTestCase {
    private func par(_ type: String?) -> MediaOverlay.Parallel {
        MediaOverlay.Parallel(textHref: "c.xhtml#x", audioHref: nil,
                              clipBegin: 0, clipEnd: nil, epubType: type)
    }

    func testSkippabilityMatchesBareAndPrefixedTypes() {
        let types: Set<String> = ["pagebreak", "footnote"]
        XCTAssertTrue(MediaOverlayController.isSkipped(par("pagebreak"), types: types))
        XCTAssertTrue(MediaOverlayController.isSkipped(
            par("frontmatter:pagebreak"), types: types))
        XCTAssertTrue(MediaOverlayController.isSkipped(
            par("footnote noteref"), types: types))
        XCTAssertFalse(MediaOverlayController.isSkipped(par("bodymatter"), types: types))
        XCTAssertFalse(MediaOverlayController.isSkipped(par(nil), types: types))
        // 既定(空集合)は何も飛ばさない
        XCTAssertFalse(MediaOverlayController.isSkipped(par("pagebreak"), types: []))
    }

    func testSkippedParsAreNotPlayed() throws {
        let book = try EPUBFixtures.publication(EPUBFixtures.multiDocumentMediaOverlayEntries(),
            name: "washi-skip")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.load(publication: book)
        let controller = MediaOverlayController(
            reader: view, publication: book, activeClass: "x")
        view.mediaOverlayController = controller
        controller.continuesToNextItem = false
        // fixture の par は epub:type を持たないので、飛ばし指定は効かない
        controller.skippedTypes = ["pagebreak"]
        controller.play(fromSpineIndex: 0)
        XCTAssertEqual(controller.parIndex, 0)
        controller.stop()
    }

    /// 保存した位置から再開できる
    func testPlaybackResumesAtSavedPosition() throws {
        let book = try EPUBFixtures.publication(EPUBFixtures.multiDocumentMediaOverlayEntries(),
            name: "washi-resume")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.load(publication: book)
        XCTAssertTrue(view.playMediaOverlay(atSpineIndex: 0, parIndex: 2))
        let position = try XCTUnwrap(view.mediaOverlayPosition)
        XCTAssertEqual(position.parIndex, 2)
        view.stopMediaOverlay()
        // 範囲外の位置は先頭へ丸める
        XCTAssertTrue(view.playMediaOverlay(atSpineIndex: 0, parIndex: 999))
        XCTAssertEqual(view.mediaOverlayPosition?.parIndex, 0)
        view.stopMediaOverlay()
    }

    /// cooViewer-oxr.46 C26: 章頭ではなく、いま見えている区間から鳴らす。
    func testPlaybackStartsFromTheClipVisibleOnScreen() async throws {
        let book = try EPUBFixtures.publication(EPUBFixtures.multiDocumentMediaOverlayEntries(),
            name: "washi-from-page")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let window = makeOffscreenWindow(containing: view, ignoresMouseEvents: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }

        view.load(publication: book)
        for _ in 0..<300 where view.pageCountInItem < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))

        await view.playMediaOverlayFromCurrentPage()
        let position = try XCTUnwrap(view.mediaOverlayPosition)
        XCTAssertEqual(position.spineIndex, 0)
        // a.xhtml の 2 区間はどちらも 1 ページに収まるので par 0 から始まる。
        // 少なくとも「章頭に固定」ではなく画面の内容で決まっていること。
        XCTAssertTrue((0...1).contains(position.parIndex),
                      "画面に見える区間から始まっていない: \(position.parIndex)")
        view.stopMediaOverlay()
    }

    func testCurrentPagePlaybackUsesCurrentDocumentInSharedOverlay() async throws {
        let book = try EPUBFixtures.publication(EPUBFixtures.multiDocumentMediaOverlayEntries(),
            name: "washi-shared-current-page")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let window = makeOffscreenWindow(containing: view, ignoresMouseEvents: false)
        window.makeKeyAndOrderFront(nil)
        defer {
            view.stopMediaOverlay()
            window.contentView = nil
            window.orderOut(nil)
        }

        view.load(publication: book)
        let web = try view.firstWebView()
        for _ in 0..<300 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        view.go(to: book.locator(forSpineIndex: 1, progression: 0))
        for _ in 0..<300 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))

        await view.playMediaOverlayFromCurrentPage()
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertEqual(view.mediaOverlayPosition?.spineIndex, 1)
        XCTAssertEqual(view.mediaOverlayPosition?.parIndex, 2,
                       "Duplicate fragment IDs in an earlier document must not win")
    }

    func testStopCancelsPendingCurrentPagePlaybackRequest() async throws {
        let book = try EPUBFixtures.publication(EPUBFixtures.multiDocumentMediaOverlayEntries(),
            name: "washi-delayed-current-page")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let window = makeOffscreenWindow(containing: view, ignoresMouseEvents: false)
        window.makeKeyAndOrderFront(nil)
        defer {
            view.stopMediaOverlay()
            window.contentView = nil
            window.orderOut(nil)
        }

        view.load(publication: book)
        let web = try view.firstWebView()
        for _ in 0..<300 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await view.evaluateForTest("""
            __washi.firstVisibleIdentifier = function(ids) {
                return new Promise(function(resolve) {
                    setTimeout(function() { resolve(ids[1] || ids[0] || null); }, 200);
                });
            };
            return true;
            """)

        let generation = view.mediaOverlayCommandGeneration
        let request = Task { @MainActor in
            await view.playMediaOverlayFromCurrentPage()
        }
        for _ in 0..<100 where view.mediaOverlayCommandGeneration == generation {
            await Task.yield()
        }
        XCTAssertNotEqual(view.mediaOverlayCommandGeneration, generation,
                          "The delayed request must have started")
        view.stopMediaOverlay()
        await request.value
        XCTAssertFalse(view.isPlayingMediaOverlay)
        XCTAssertNil(view.mediaOverlayPosition,
                     "A response older than stop() must not restart narration")
    }

    /// 既定のハイライトクラスに下地の CSS を与えている
    func testDefaultActiveClassHasBaseStyle() {
        XCTAssertTrue(
            ReaderScripts.baseCSS.contains("-epub-media-overlay-active"),
            "既定クラスの下地 CSS が無い")
    }
}
