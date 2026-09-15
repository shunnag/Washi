import AppKit
import XCTest
@testable import Washi

@MainActor
private final class UnsupportedHTMLDelegate: EPUBReaderViewDelegate {
    var moves = 0
    var failures: [any Error] = []
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) { moves += 1 }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) { failures.append(error) }
}

@MainActor
final class UnsupportedHTMLSpineTests: XCTestCase {
    func testRejectedHTMLSpineCannotUsePreviousXHTMLDocumentForExactPositions() async throws {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: "<p>和紙の本文</p>")
        let package = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        entries[package].data = Data(String(decoding: entries[package].data, as: UTF8.self)
            .replacingOccurrences(of: "</manifest>", with:
                "<item id=\"html\" href=\"text/nonconforming.html\" media-type=\"text/html\"/></manifest>")
            .replacingOccurrences(of: "</spine>", with: "<itemref idref=\"html\"/></spine>").utf8)
        entries.append(("OEBPS/text/nonconforming.html", Data("<html><body><p>和紙の別の本文</p></body></html>".utf8)))
        let book = try EPUBPublication(data: ZipBuilder.build(entries),
                                       displayURL: URL(fileURLWithPath: "/tmp/nonconforming-html.epub"))
        let hit = try XCTUnwrap(book.search("和紙").first { $0.spineIndex == 1 })
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let delegate = UnsupportedHTMLDelegate()
        view.delegate = delegate
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.unload(); window.contentView = nil; window.close() }
        view.load(publication: book)
        let deadline = ContinuousClock.now + .seconds(10)
        while delegate.moves == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(delegate.moves, 0)
        XCTAssertTrue(delegate.failures.isEmpty)

        view.go(to: book.locator(forSpineIndex: 1))
        XCTAssertEqual(delegate.failures.count, 1)
        let landing = await view.go(to: book.locator(forSpineIndex: 1),
                                    textRange: (hit.utf16Range.lowerBound, hit.utf16Range.count))
        XCTAssertNil(landing, "表示を拒否した HTML の範囲を、残っている前章の DOM で解決しない")
        let rects = await view.rects(forTextRange: hit.utf16Range, inSpineIndex: 1)
        XCTAssertTrue(rects.isEmpty)
        let locator = await view.currentLocatorWithTextAnchor()
        XCTAssertNil(locator.textOffset)
    }
}
