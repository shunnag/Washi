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
    return try EPUBPublication(data: ZipBuilder.build(entries, method: 8),
                               displayURL: URL(fileURLWithPath: "/tmp/scroll-tests.epub"))
}

@MainActor
final class ScrollReaderHarness: EPUBReaderViewDelegate {
    let reader = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let window: NSWindow
    var moves = 0
    var failures: [any Error] = []
    var edges: [Bool] = []

    init() {
        window = NSWindow(contentRect: reader.frame.offsetBy(dx: -20_000, dy: -20_000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        reader.settings.insets = .zero
        reader.settings.columnMode = .double
        reader.settings.pageTurnStyle = .none
        reader.delegate = self
        window.contentView = reader
    }

    func close() {
        reader.unload()
        reader.delegate = nil
        window.contentView = nil
        window.close()
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

@MainActor
final class EPUBScrollLayoutTests: XCTestCase {
    func testRollDisplaysSVGAndRasterSpineResourcesAtIntrinsicAspectRatio() async throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="800" viewBox="0 0 200 800">
        <rect width="200" height="800" fill="cornflowerblue"/><text x="10" y="500">和紙</text></svg>
        """.utf8)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for (name, type, data) in [("page.svg", "image/svg+xml", svg), ("page.png", "image/png", png)] {
            let book = try EPUBPublication(data: ZipBuilder.build([
                ("mimetype", Data("application/epub+zip".utf8)),
                ("META-INF/container.xml", Data("""
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
                <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
                """.utf8)),
                ("book.opf", Data("""
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">roll-media</dc:identifier><dc:title>画像</dc:title><dc:language>ja</dc:language>
                <meta property="rendition:layout">roll</meta></metadata>
                <manifest><item id="page" href="\(name)" media-type="\(type)"/></manifest>
                <spine><itemref idref="page"/></spine></package>
                """.utf8)), (name, data)
            ], method: 8), displayURL: URL(fileURLWithPath: "/tmp/roll-media.epub"))
            let harness = ScrollReaderHarness()
            defer { harness.close() }
            try await harness.load(book)
            let metrics = try await harness.metrics()
            XCTAssertEqual(try XCTUnwrap(metrics["extent"] as? Double), 2000, accuracy: 1, name)
            let dimensions = try await harness.reader.evaluateForTest("""
                const doc = __washi.activeDocument();
                const image = doc.querySelector('img') || doc.documentElement;
                const rect = image.getBoundingClientRect();
                return [rect.width, rect.height];
                """)
            XCTAssertEqual(dimensions as? [Double], [200, 800], name)
            let thumbnail = await harness.reader.screenThumbnail(spineIndex: 0, pageInItem: 3, width: 200)
            XCTAssertNotNil(thumbnail, name)
            try await saveSnapshot(harness.reader, name: "roll-" + name)
        }
    }

    func testFlowOverridesAndContinuousGroups() throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: Array(repeating: "horizontal-tb", count: 4),
                                         overrides: ["", "", "rendition:flow-scrolled-doc rendition:flow-paginated", ""])
        XCTAssertEqual(book.scrollGroup(containing: 1), 0..<2)
        XCTAssertEqual(book.scrollGroup(containing: 2), 2..<3)
        XCTAssertEqual(book.scrollGroup(containing: 3), 3..<4)
        XCTAssertEqual(book.package.effectiveFlow(for: book.readingOrder[2].itemRef), .scrolledDoc)
        let roll = try scrollPublication(flow: "paginated", layout: "roll", overrides: ["rendition:layout-reflowable rendition:flow-paginated"])
        XCTAssertEqual(roll.package.effectiveLayout(for: roll.readingOrder[0].itemRef), .roll)
        XCTAssertEqual(roll.renderingFlow(at: 0), .scrolledContinuous)
    }

    func testScrollMetricsUseSingleInsetsEvenWhenDoubleColumnsRequested() {
        var settings = EPUBReaderSettings()
        settings.columnMode = .double
        settings.insets = .zero
        settings.spreadInsets = EPUBReaderInsets(top: 20, left: 20, bottom: 20, right: 20)
        let base = EPUBScreenMetrics(viewportSize: CGSize(width: 800, height: 600), settings: settings)
        let scroll = base.applyingRenditionFlow(.scrolledDoc)
        XCTAssertEqual(scroll.pagesPerScreen, 1)
        XCTAssertEqual(scroll.contentSize, CGSize(width: 800, height: 600))
        XCTAssertNotEqual(scroll.cacheKey, base.cacheKey)
        XCTAssertEqual(scroll.applyingRenditionSpread(.both).pagesPerScreen, 1)
        XCTAssertEqual(scroll.applyingRenditionFlow(.paginated).pagesPerScreen, 2)
    }

    func testAtlasUsesEachItemsFlowForScreenEnumeration() throws {
        let book = try scrollPublication(flow: "paginated", modes: ["horizontal-tb", "horizontal-tb"],
                                         overrides: ["", "rendition:flow-scrolled-doc"])
        let atlas = EPUBScreenAtlas(publication: book)
        defer { atlas.invalidate() }
        var settings = EPUBReaderSettings()
        settings.columnMode = .double
        let metrics = EPUBScreenMetrics(viewportSize: CGSize(width: 800, height: 600), settings: settings)
        XCTAssertEqual(atlas.pagesPerScreen(forSpineIndex: 0, metrics: metrics), 2)
        XCTAssertEqual(atlas.pagesPerScreen(forSpineIndex: 1, metrics: metrics), 1)
        XCTAssertNil(atlas.pagesPerScreen(forSpineIndex: 2, metrics: metrics))
    }

    func testContinuousCensusLocatorRoundTripsToVisibleScreen() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["horizontal-tb", "horizontal-tb"])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book)
        let reader = harness.reader
        try await harness.wait { reader.censusTotalPages != nil }
        let count = try XCTUnwrap(reader.censusTotalPages)
        XCTAssertGreaterThan(count, 2)
        for page in 0..<count {
            let locator = try XCTUnwrap(reader.censusLocator(forGlobalPage: page))
            XCTAssertEqual(reader.censusGlobalPage(for: locator), page)
            let before = harness.moves
            reader.go(to: locator)
            try await harness.wait { harness.moves > before }
            XCTAssertEqual(reader.currentGlobalPageRange?.lowerBound, page + 1)
            XCTAssertEqual(reader.censusGlobalPage(for: reader.currentLocator), page)
        }
    }

    func testContinuousWheelKeepsSmallDeltas() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["horizontal-tb", "horizontal-tb"])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book)
        let accepted = try await harness.reader.evaluateForTest("""
            const frame = document.querySelector('iframe');
            const event = new frame.contentWindow.WheelEvent('wheel', {
                deltaY: 35, bubbles: true, cancelable: true
            });
            frame.contentDocument.body.dispatchEvent(event);
            return event.defaultPrevented;
            """)
        XCTAssertEqual(accepted as? Bool, true)
        let metrics = try await harness.metrics()
        XCTAssertEqual(try XCTUnwrap(metrics["offset"] as? Double), 35, accuracy: 1)
    }

    func testContinuousGroupBoundariesReturnToPaginatedChapters() async throws {
        let book = try scrollPublication(flow: "paginated", modes: Array(repeating: "horizontal-tb", count: 4),
                                         overrides: ["", "rendition:flow-scrolled-continuous",
                                                     "rendition:flow-scrolled-continuous", ""])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book, at: book.locator(forSpineIndex: 2, progression: 1))
        XCTAssertEqual(harness.reader.pagesPerScreen, 1)
        harness.reader.goForward()
        try await harness.wait { harness.reader.currentSpineIndex == 3 && harness.reader.pagesPerScreen == 2 }
        harness.reader.go(to: book.locator(forSpineIndex: 1))
        try await harness.wait { harness.reader.currentSpineIndex == 1 && harness.reader.pagesPerScreen == 1 }
        harness.reader.goBackward()
        try await harness.wait { harness.reader.currentSpineIndex == 0 && harness.reader.pagesPerScreen == 2 }
        XCTAssertTrue(harness.failures.isEmpty)
    }

    func testContinuousTextAnchorRestoresVisibleTextAfterResize() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["horizontal-tb", "horizontal-tb"])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book, at: book.locator(forSpineIndex: 1, progression: 0.55))
        let locator = await harness.reader.currentLocatorWithTextAnchor()
        let offset = try XCTUnwrap(locator.textOffset)
        harness.reader.frame.size = CGSize(width: 420, height: 300)
        try await harness.load(book, at: locator)
        let rects = await harness.reader.rects(forTextRange: offset..<(offset + 1), inSpineIndex: 1)
        XCTAssertTrue(rects.contains { $0.intersects(harness.reader.contentFrame) })
        XCTAssertTrue(harness.failures.isEmpty)
    }

    func testContinuousResizeUpdatesGeometryAndPreservesPosition() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["vertical-lr", "vertical-lr"])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book, at: book.locator(forSpineIndex: 1, progression: 0.55))
        harness.reader.frame.size = CGSize(width: 380, height: 300)
        harness.reader.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(15)
        var metrics = try await harness.metrics()
        while metrics["viewport"] as? Double != 380, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            metrics = try await harness.metrics()
        }
        XCTAssertEqual(metrics["viewport"] as? Double, 380)
        XCTAssertEqual(harness.reader.currentSpineIndex, 1)
        XCTAssertEqual(harness.reader.currentLocator.progression, 0.55, accuracy: 0.01)
        XCTAssertTrue(harness.failures.isEmpty)
    }

    func testUnchangedContinuousLayoutPreservesFramesAndScrollInput() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["horizontal-tb", "horizontal-tb"])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book)
        _ = try await harness.metrics()
        let options = harness.reader.setupOptionsJSON()
        let value = try await harness.reader.evaluateForTest("""
            const frame = document.querySelector('iframe');
            const pending = __washi.repaginate(\(options));
            window.scrollTo(0, 137);
            await pending;
            return { sameFrame: frame === document.querySelector('iframe'),
                     offset: __washi.scrollMetrics().offset };
            """)
        let result = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(result["sameFrame"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(result["offset"] as? Double), 137, accuracy: 1)
    }

    func testHorizontalDocumentScrollsWithoutColumnsOrSnapping() async throws {
        try await verifyDocument(mode: "horizontal-tb", horizontal: false, negative: false)
    }

    func testVerticalRLDocumentScrollsLeftWithoutColumnsOrSnapping() async throws {
        try await verifyDocument(mode: "vertical-rl", horizontal: true, negative: true)
    }

    func testVerticalLRDocumentScrollsRightWithoutColumnsOrSnapping() async throws {
        try await verifyDocument(mode: "vertical-lr", horizontal: true, negative: false)
    }

    func testContinuousHorizontalChaptersShareOneScrollAndPreserveIdentity() async throws {
        try await verifyContinuous(mode: "horizontal-tb")
    }

    func testContinuousVerticalRLChaptersShareOneScrollAndPreserveIdentity() async throws {
        try await verifyContinuous(mode: "vertical-rl")
    }

    func testContinuousVerticalLRChaptersShareOneScrollAndPreserveIdentity() async throws {
        try await verifyContinuous(mode: "vertical-lr")
    }

    private func verifyContinuous(mode: String) async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: [mode, mode])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book)
        let reader = harness.reader
        let webView = try XCTUnwrap(reader.subviews.first { $0 is WKWebView })
        let initial = try await harness.metrics()
        let items = try XCTUnwrap(initial["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let secondStart = try XCTUnwrap((items[1]["start"] as? NSNumber)?.doubleValue, "\(initial)")
        let horizontal = mode != "horizontal-tb"
        let sign = mode == "vertical-rl" ? -1.0 : 1.0
        let boundaryPosition = (secondStart - 120) * sign
        _ = try await reader.evaluateForTest("window.scrollTo(\(horizontal ? boundaryPosition : 0), \(horizontal ? 0 : boundaryPosition)); return true;")
        try await Task.sleep(for: .milliseconds(300))
        let boundary = try await harness.metrics()
        XCTAssertEqual(try XCTUnwrap(boundary["offset"] as? Double), secondStart - 120, accuracy: 1)
        let boundaryItems = try XCTUnwrap(boundary["items"] as? [[String: Any]])
        try await saveSnapshot(reader, name: "continuous-\(mode)")
        let secondRect = try XCTUnwrap(boundaryItems[1]["rect"] as? [String: Any])
        if mode == "vertical-rl" {
            let right = try XCTUnwrap(secondRect["x"] as? Double) + XCTUnwrap(secondRect["w"] as? Double)
            XCTAssertEqual(right, 380, accuracy: 1)
        } else {
            XCTAssertEqual(try XCTUnwrap(secondRect[horizontal ? "x" : "y"] as? Double), 120, accuracy: 1)
        }
        let position = (secondStart + 137) * sign
        _ = try await reader.evaluateForTest("window.scrollTo(\(horizontal ? position : 0), \(horizontal ? 0 : position)); return true;")
        try await harness.wait { reader.currentSpineIndex == 1 }
        XCTAssertTrue(reader.subviews.contains { $0 === webView })
        let saved = reader.currentLocator
        XCTAssertGreaterThan(saved.progression, 0)
        try await harness.load(book, at: saved)
        let restored = try await harness.metrics()
        XCTAssertEqual(try XCTUnwrap(restored["offset"] as? Double), secondStart + 137, accuracy: 1)
        let census = EPUBPaginationCensus()
        defer { census.invalidate() }
        let metrics = EPUBScreenMetrics(viewportSize: reader.bounds.size, settings: reader.settings)
        let counts = await census.measure(publication: book, optionsJSON: metrics.censusOptionsJSON,
                                          contentSize: metrics.contentSize)
        XCTAssertEqual(counts, items.compactMap { $0["pageCount"] as? Int })
        let image = await reader.screenThumbnail(spineIndex: 0, pageInItem: 2, width: 200)
        XCTAssertNotNil(image)
        let hit = try XCTUnwrap(book.search("第12段落").first)
        let landing = await reader.go(to: book.locator(forSpineIndex: 0),
                                      textRange: (hit.utf16Range.lowerBound, hit.utf16Range.count))
        let landed = try XCTUnwrap(landing)
        XCTAssertEqual(reader.currentSpineIndex, 0)
        XCTAssertTrue(landed.rects.contains { $0.intersects(reader.contentFrame) })
        reader.goToBookEnd()
        try await harness.wait { reader.currentSpineIndex == 1 && reader.pageCountInItem > 1
            && reader.pageInItem == reader.pageCountInItem - 1 }
        reader.goForward()
        try await harness.wait { harness.edges == [true] }
    }

    func testRollAndLegacyFixedContinuousFitWidthAndJoinWithoutGap() async throws {
        for layout in ["roll", "pre-paginated"] {
            let book = try scrollPublication(flow: "scrolled-continuous", layout: layout,
                                             modes: ["horizontal-tb", "horizontal-tb"])
            let harness = ScrollReaderHarness()
            defer { harness.close() }
            harness.reader.settings.insets = EPUBReaderInsets(top: 20, left: 20, bottom: 20, right: 20)
            try await harness.load(book)
            XCTAssertEqual(harness.reader.contentFrame, harness.reader.bounds)
            let metrics = try await harness.metrics()
            let items = try XCTUnwrap(metrics["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(try XCTUnwrap(items[0]["extent"] as? Double), 1600, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(items[1]["start"] as? Double), 1600, accuracy: 1)
            let rect = try XCTUnwrap(items[0]["rect"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(rect["w"] as? Double), 500, accuracy: 1)
            _ = try await harness.reader.evaluateForTest("window.scrollTo(0, 1500); return true;")
            try await Task.sleep(for: .milliseconds(300))
            let moved = try await harness.metrics()
            XCTAssertEqual(try XCTUnwrap(moved["offset"] as? Double), 1500, accuracy: 1)
            try await saveSnapshot(harness.reader, name: layout)
            let image = await harness.reader.screenThumbnail(spineIndex: 0, pageInItem: 3, width: 200)
            XCTAssertNotNil(image)
            let hit = try XCTUnwrap(book.search("第12段落").first)
            let landing = await harness.reader.go(to: book.locator(forSpineIndex: 0),
                                                 textRange: (hit.utf16Range.lowerBound, hit.utf16Range.count))
            XCTAssertTrue(try XCTUnwrap(landing).rects.contains { $0.intersects(harness.reader.contentFrame) })
        }
    }

    func testLongRollLoadsNearbyChaptersAndReleasesDistantFrames() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", layout: "roll",
                                         modes: Array(repeating: "horizontal-tb", count: 20))
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book)
        var metrics = try await harness.metrics()
        var items = try XCTUnwrap(metrics["items"] as? [[String: Any]])
        XCTAssertLessThan(items.filter { $0["loaded"] as? Bool == true }.count, 4)
        let start = try XCTUnwrap(items[15]["start"] as? Double)
        _ = try await harness.reader.evaluateForTest("window.scrollTo(0, \(start + 100)); return true;")
        try await harness.wait { harness.reader.currentSpineIndex == 15 }
        let ready = try await harness.reader.evaluateForTest("return __washi.visibleTextOffset();")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ready as? Int), 0)
        metrics = try await harness.metrics()
        items = try XCTUnwrap(metrics["items"] as? [[String: Any]])
        XCTAssertLessThan(items.filter { $0["loaded"] as? Bool == true }.count, 4)
        XCTAssertEqual(items[0]["loaded"] as? Bool, false)
        XCTAssertEqual(items[15]["loaded"] as? Bool, true)
        XCTAssertTrue(harness.failures.isEmpty)
    }

    private func saveSnapshot(_ reader: EPUBReaderView, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["WASHI_SCROLL_SNAPSHOT_DIR"] else { return }
        let image = try await reader.snapshot()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }

    private func verifyDocument(mode: String, horizontal: Bool, negative: Bool) async throws {
        let book = try scrollPublication(modes: [mode])
        let harness = ScrollReaderHarness()
        defer { harness.close() }
        try await harness.load(book)
        let reader = harness.reader
        XCTAssertEqual(reader.pagesPerScreen, 1)
        XCTAssertEqual(reader.plannedPagesPerScreen, 1)
        XCTAssertGreaterThan(reader.pageCountInItem, 1)
        let column = try await reader.evaluateForTest("return getComputedStyle(document.documentElement).columnWidth;")
        XCTAssertEqual(column as? String, "auto")
        // 半端な位置へ実際にスクロールしてもページ境界へ引き戻されない。
        let offset = negative ? -137 : 137
        _ = try await reader.evaluateForTest("window.scrollTo(\(horizontal ? offset : 0), \(horizontal ? 0 : offset)); return true;")
        try await harness.wait { reader.currentLocator.progression > 0 }
        try await Task.sleep(for: .milliseconds(200))
        let moved = try await harness.metrics()
        XCTAssertEqual(try XCTUnwrap(moved["offset"] as? Double), 137, accuracy: 1)
        let saved = reader.currentLocator
        XCTAssertGreaterThan(saved.progression, 0)
        try await harness.load(book, at: saved)
        try await harness.wait { abs(reader.currentLocator.progression - saved.progression) < 0.002 }
        let restored = try await harness.metrics()
        XCTAssertEqual(try XCTUnwrap(restored["offset"] as? Double), 137, accuracy: 1)

        let census = EPUBPaginationCensus()
        defer { census.invalidate() }
        let metrics = EPUBScreenMetrics(viewportSize: reader.bounds.size, settings: reader.settings)
        let counts = await census.measure(publication: book, optionsJSON: metrics.censusOptionsJSON,
                                          contentSize: metrics.contentSize)
        XCTAssertEqual(counts, [reader.pageCountInItem])
        let image = await reader.screenThumbnail(spineIndex: 0, pageInItem: reader.pageCountInItem - 1, width: 200)
        XCTAssertNotNil(image)
        // 検索の範囲移動もスクロール上の可視範囲へ着地する。
        let hit = try XCTUnwrap(book.search("第12段落").first)
        let landing = await reader.go(to: book.locator(forSpineIndex: 0),
                                      textRange: (hit.utf16Range.lowerBound, hit.utf16Range.count))
        XCTAssertNotNil(landing)
        XCTAssertGreaterThan(reader.currentLocator.progression, saved.progression)
    }
}
