import AppKit
import WebKit
import XCTest
@testable import Washi

func scrollPublication(flow: String = "scrolled-doc", layout: String = "reflowable",
                       modes: [String] = ["horizontal-tb"], overrides: [String] = []) throws -> EPUBPublication {
    let manifest = modes.indices.map {
        "<item id=\"c\($0)\" href=\"c\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
    }.joined()
    let spine = modes.indices.map {
        "<itemref idref=\"c\($0)\" properties=\"\(overrides.indices.contains($0) ? overrides[$0] : "")\"/>"
    }.joined()
    let package = """
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">scroll-tests</dc:identifier><dc:title>スクロール</dc:title>
    <dc:language>ja</dc:language><meta property="rendition:flow">\(flow)</meta>
    <meta property="rendition:layout">\(layout)</meta></metadata>
    <manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
    """
    var entries: [(name: String, data: Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8)),
        ("book.opf", Data(package.utf8))
    ]
    for (index, mode) in modes.enumerated() {
        let paragraphs = (0..<16).map {
            "<p id=\"p\($0)\" style=\"margin:0;block-size:80px\">第\(index + 1)章 第\($0)段落 和紙の本文です。</p>"
        }.joined()
        entries.append(("c\(index).xhtml", Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" style="writing-mode:\(mode)">
        <head><title>章\(index)</title><meta name="viewport" content="width=400,height=1280"/></head>
        <body>\(paragraphs)</body></html>
        """.utf8)))
    }
    return try EPUBFixtures.publication(entries, name: "scroll-tests")
}

@MainActor
final class ScrollReaderHarness: EPUBReaderViewDelegate {
    let reader = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let window: NSWindow
    var moves = 0
    var failures: [any Error] = []
    var edges: [Bool] = []

    init() {
        reader.settings.insets = .zero
        reader.settings.columnMode = .double
        reader.settings.pageTurnStyle = .none
        window = makeOffscreenWindow(containing: reader, ignoresMouseEvents: false)
        reader.delegate = self
    }

    func close() {
        closeReader(reader, in: window, teardown: .unload, clearsDelegate: true)
    }

    func load(_ book: EPUBPublication, at locator: EPUBLocator? = nil) async throws {
        moves = 0
        reader.load(publication: book, at: locator)
        try await wait { self.moves > 0 || !self.failures.isEmpty }
        XCTAssertTrue(failures.isEmpty, failures.description)
        XCTAssertGreaterThan(moves, 0)
    }

    func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "スクロール表示の応答がない", file: file, line: line)
    }

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) { moves += 1 }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) { failures.append(error) }
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) { edges.append(forward) }

    func metrics() async throws -> [String: Any] {
        // 位置通知の後にも AppKit の初回 layout が再計測を予約する場合がある。
        // 連続表示は章の読み込みが非同期なので、途中の未確定寸法を検査しない。
        let value = try await reader.evaluateForTest("""
            const deadline = Date.now() + 10000;
            while (!__washi.scrollMetrics().ready && Date.now() < deadline) {
                await new Promise(resolve => setTimeout(resolve, 20));
            }
            return __washi.scrollMetrics();
            """)
        let metrics = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(metrics["ready"] as? Bool, true, "レイアウトが確定しない: \(metrics)")
        return metrics
    }
}

