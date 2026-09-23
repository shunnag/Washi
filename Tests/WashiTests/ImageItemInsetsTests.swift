import AppKit
import WebKit
import XCTest
@testable import Washi

// 画像 1 枚だけの項目(表紙・挿絵)は余白なしの全面、文字の項目は余白の内側。
// census・画面サムネイルも同じ判断(EPUBScreenMetrics.fillsViewport)を使う。

/// ページ割りが終わるたびに数える(読み込み完了の待ちに使う)
@MainActor
private final class LayoutCountingDelegate: EPUBReaderViewDelegate {
    var moves = 0
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moves += 1
    }
}

@MainActor
final class ImageItemInsetsTests: XCTestCase {
    /// 画像 1 枚だけの項目 `imageItems` 個と、文字の項目 `textItems` 個
    /// （1 項目あたり `charactersPerTextItem` 文字）の本を作る。
    /// 並びは画像の項目が先、文字の項目が後。
    private func makeBook(imageItems: Int, textItems: Int,
                          charactersPerTextItem: Int) throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
            unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:image-only-items</dc:identifier>
                <dc:title>Image-only items</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-19T00:00:00Z</meta>
              </metadata>
              <manifest>MANIFEST<item id="image" href="images/page.png" \
            media-type="image/png"/></manifest>
              <spine>SPINE</spine>
            </package>
            """
        var manifest = ""
        var spine = ""
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/images/page.png", EPUBFixtures.tinyPNG),
        ]
        func append(id: String, body: String) {
            manifest += "<item id=\"\(id)\" href=\"text/\(id).xhtml\" "
                + "media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"\(id)\"/>"
            // singleSpineEntries と同じ形(XML 宣言と head つき)にする。
            // 省くと WebKit が XHTML として読めず、ページ割りが始まらない
            entries.append(("OEBPS/text/\(id).xhtml", Data(
                ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                 + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
                 + "<head><meta charset=\"UTF-8\"/>"
                 + "<style>body{font-size:20px;line-height:1.8}</style></head>"
                 + "<body>" + body + "</body></html>").utf8)))
        }
        for i in 0..<imageItems {
            append(id: "img\(i)", body: "<img src=\"../images/page.png\"/>")
        }
        let paragraph = String(repeating: "本", count: max(1, charactersPerTextItem))
        for i in 0..<textItems {
            append(id: "txt\(i)", body: "<p>" + paragraph + "</p>")
        }
        entries.append(("OEBPS/package.opf", Data(opf
            .replacingOccurrences(of: "MANIFEST", with: manifest)
            .replacingOccurrences(of: "SPINE", with: spine).utf8)))
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-image-only-items.epub"))
    }

    /// ライトノベル型: 挿絵 27 項目＋文字の章 13 項目。
    private func makePublication() throws -> EPUBPublication {
        try makeBook(imageItems: 27, textItems: 13, charactersPerTextItem: 4_000)
    }

    private func makeView() -> EPUBReaderView {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(top: 20, left: 40, bottom: 20, right: 40)
        settings.spreadInsets = nil
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        view.settings = settings
        return view
    }

    private func webView(of view: EPUBReaderView) throws -> NSView {
        try XCTUnwrap(view.subviews.first { $0 is WKWebView })
    }

    /// ノンブル(NSTextField)。cooViewer-oxr.35 の既存テストと同じ取り出し方。
    private func pageNumberLabels(of view: EPUBReaderView) -> [NSTextField] {
        view.subviews.compactMap { $0 as? NSTextField }
    }

    /// 文字主体の本でも、画像 1 枚だけの項目は枠いっぱい。
    func testImageOnlyItemFillsTheViewEvenInATextBook() throws {
        let view = makeView()
        view.load(publication: try makePublication(),
                  at: EPUBLocator(spineIndex: 0, progression: 0))
        XCTAssertEqual(try webView(of: view).frame, view.bounds)
        XCTAssertEqual(view.contentFrame,
                       NSRect(origin: .zero, size: view.bounds.size))
    }

    func testTextItemKeepsTheInsets() throws {
        let view = makeView()
        // 先頭 27 項目が挿絵、その後ろが文字の章(makeBook の並び)
        view.load(publication: try makePublication(),
                  at: EPUBLocator(spineIndex: 27, progression: 0))
        XCTAssertEqual(try webView(of: view).frame,
                       NSRect(x: 40, y: 20, width: 1_200 - 80, height: 900 - 40))
    }

    /// scrolled-doc の画像だけの項目は余白を残す(ページ数が高さに依存するため)。
    func testScrolledImageOnlyItemKeepsTheInsets() throws {
        var entries = EPUBFixtures.imagePageEntries(
            bodyHTML: "<img src=\"../images/page.png\"/>")
        let packageIndex = try XCTUnwrap(
            entries.firstIndex { $0.name == "OEBPS/package.opf" })
        let package = String(decoding: entries[packageIndex].data, as: UTF8.self)
            .replacingOccurrences(
                of: #"<spine><itemref idref="c"/></spine>"#,
                with: #"<spine><itemref idref="c" properties="rendition:flow-scrolled-doc"/></spine>"#)
        entries[packageIndex].data = Data(package.utf8)
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-image-item-insets-scrolled.epub"))
        let view = makeView()
        view.load(publication: publication,
                  at: EPUBLocator(spineIndex: 0, progression: 0))
        XCTAssertEqual(try webView(of: view).frame,
                       NSRect(x: 40, y: 20, width: 1_200 - 80, height: 900 - 40))
    }

    /// 画像だけの項目ではノンブルも(JS のページ割り結果を待たず)読み込み時に隠れる。
    func testImageOnlyItemHidesPageFurniture() throws {
        // 先頭 27 項目が挿絵、その後ろが文字の章(makeBook の並び)
        let publication = try makePublication()
        let view = makeView()
        view.load(publication: publication,
                  at: EPUBLocator(spineIndex: 27, progression: 0))
        XCTAssertTrue(pageNumberLabels(of: view).contains { !$0.isHidden },
                     "文字の項目ではノンブルが見えている前提")

        view.load(publication: publication,
                  at: EPUBLocator(spineIndex: 0, progression: 0))
        XCTAssertTrue(pageNumberLabels(of: view).allSatisfy(\.isHidden))
    }

    /// census・画面サムネイルの全面判断が、表示中の contentFrame と項目ごとに一致する。
    func testOffscreenFullViewportMatchesTheLiveViewPerItem() throws {
        let publication = try makePublication()
        for index in [0, 26, 27, 39] {
            let view = makeView()
            view.load(publication: publication,
                      at: EPUBLocator(spineIndex: index, progression: 0))
            let liveFills = view.contentFrame == NSRect(origin: .zero, size: view.bounds.size)
            XCTAssertEqual(EPUBScreenMetrics.fillsViewport(publication, spineIndex: index),
                           liveFills, "spine \(index)")
            XCTAssertEqual(liveFills, index < 27, "spine \(index): 挿絵だけが全面")
        }
    }

    private func waitUntil(timeout: Duration = .seconds(8),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// 文字 → 画像 → 文字: 項目ごとに矩形が変わるが、当てるのはコミット時。
    /// 呼び出し直後は前の矩形のまま、読み込み後に新しい矩形になる。
    func testFrameMovesAtCommitAcrossTextAndImageItems() async throws {
        // 並びは img0, txt0, txt1
        let publication = try makeBook(imageItems: 1, textItems: 2,
                                       charactersPerTextItem: 400)
        let view = makeView()
        let delegate = LayoutCountingDelegate()
        view.delegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        view.load(publication: publication,
                  at: EPUBLocator(spineIndex: 1, progression: 0))
        let web = try webView(of: view)
        // ページ割りの通知と表示の復帰を待つ(透明なうちは即時に当てる扱いになるため)
        func waitUntilShown(after moves: Int) async throws {
            guard await waitUntil({ delegate.moves > moves }) else {
                return try failOrSkipWebKitTest(
                    "WKWebView navigation is unavailable in this sandbox")
            }
            let shown = await waitUntil { web.alphaValue == 1 }
            XCTAssertTrue(shown)
        }
        let inset = NSRect(x: 40, y: 20, width: 1_200 - 80, height: 900 - 40)
        let full = NSRect(origin: .zero, size: view.bounds.size)
        try await waitUntilShown(after: 0)
        XCTAssertEqual(web.frame, inset)

        var moves = delegate.moves
        view.go(to: EPUBLocator(spineIndex: 0, progression: 0))
        XCTAssertEqual(web.frame, inset, "Text to image: before the commit")
        try await waitUntilShown(after: moves)
        XCTAssertEqual(web.frame, full, "Text to image: after the load")

        moves = delegate.moves
        view.go(to: EPUBLocator(spineIndex: 2, progression: 0))
        XCTAssertEqual(web.frame, full, "Image to text: before the commit")
        try await waitUntilShown(after: moves)
        XCTAssertEqual(web.frame, inset, "Image to text: after the load")
    }
}
