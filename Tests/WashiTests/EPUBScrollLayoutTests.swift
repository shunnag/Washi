import AppKit
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

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
            let book = try EPUBFixtures.publication([
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
            ], name: "roll-media")
            let harness = ScrollReaderHarness()
            defer { harness.close() }
            try await harness.load(book)
            let metrics = try await harness.metrics()
            XCTAssertEqual(try XCTUnwrap(metrics["extent"] as? Double), 2000, accuracy: 1, name)
            let dimensions = try await harness.reader.evaluateForTest("""
                const doc = __washi.activeDocument();
                const image = doc.querySelector('img') || doc.documentElement;
                const rect = image.getBoundingClientRect();
                return [rect.x, rect.y, rect.width, rect.height];
                """)
            XCTAssertEqual(dimensions as? [Double], [0, 0, 200, 800], name)
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
            reader.go(to: locator)
            // 章をまたぐ移動は連続文書の読み込み直しを伴い、setup の章頭 scroll の echo が
            // 目的の位置より先に didMoveTo を届け得る(錨のない進行率の移動なので着地待ちの
            // 対象外)。最初の報告ではなく、目的のページになるまで待つ
            try await harness.wait { reader.currentGlobalPageRange?.lowerBound == page + 1 }
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
        harness.reader.layoutSubtreeIfNeeded()
        try await harness.load(book, at: locator)
        // 新しい寸法で割り付いた JS のレイアウト(横書きの viewport は高さ)を
        // 確かめてから測る。錨への着地は load が待っている。
        _ = try await harness.metrics(untilViewport: 300)
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
        _ = try await harness.metrics(untilViewport: 380)
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
        let webView = try reader.firstWebView()
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

/// Washi-1nm: WebKit の起動時間を含めず、MainActor 上の同期 setup を検査する。
@MainActor
final class EPUBScrollDocumentTests: XCTestCase {
    func testLargeRollSetupStaysUnderOneSecond() throws {
        // 縮退直前の 4,096 項目で、寸法取得と JSON 生成が最大になる setup を測る。
        // 繰り返し itemref・1 MiB の本文・deflate は実測された細工 EPUB に揃える。
        let count = EPUBPublication.maximumEagerScrollItems
        let chapter = dimensionChapter(bodyBytes: 1_048_576)
        let book = try budgetPublication(count: count, chapter: chapter)
        let handler = EPUBSchemeHandler(publication: book)
        let start = ContinuousClock.now
        let json = EPUBScrollDocument.options(
            "{\"width\":400,\"height\":600}", publication: book, index: 0, handler: handler)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1), "同期 setup: \(elapsed)")
        print("[Washi-1nm] \(count) roll items: \(elapsed)")
        XCTAssertEqual(try decodeOptions(json)["flow"] as? String,
                       RenditionFlow.scrolledContinuous.rawValue)
        let items = try continuousItems(in: json)
        XCTAssertEqual(items.count, count)
        let exactCount = EPUBScrollDocument.maximumDimensionBytes / chapter.count
        XCTAssertGreaterThan(exactCount, 0)
        XCTAssertEqual(items[exactCount - 1]["width"] as? Int, 600)
        XCTAssertEqual(items[exactCount]["width"] as? Int, 1200)
        XCTAssertEqual(items.last?["height"] as? Int, 1600)
        XCTAssertNil(book.cachedFixedLayoutInfo(forSpineIndex: exactCount))
    }

    func testRollDimensionItemBudgetAndCachedDeviceViewport() throws {
        let limit = EPUBScrollDocument.maximumExactDimensionItems
        let book = try budgetPublication(count: limit + 2, chapter: dimensionChapter())
        let handler = EPUBSchemeHandler(publication: book)
        let items = try continuousItems(in: EPUBScrollDocument.options(
            "{}", publication: book, index: 0, handler: handler))
        XCTAssertEqual(items[limit - 1]["width"] as? Int, 600)
        XCTAssertEqual(items[limit]["width"] as? Int, 1200)
        XCTAssertNil(book.cachedFixedLayoutInfo(forSpineIndex: limit))
        // 予算不足は確定値として保存せず、後から正確に取得できる。
        XCTAssertEqual(try book.fixedLayoutInfo(forSpineIndex: limit).viewportSize,
                       CGSize(width: 600, height: 900))

        let deviceBook = try budgetPublication(
            count: limit + 2,
            chapter: dimensionChapter(viewport: "width=device-width,height=device-height"))
        _ = try deviceBook.fixedLayoutInfo(forSpineIndex: limit + 1)
        let deviceHandler = EPUBSchemeHandler(publication: deviceBook)
        for (width, height) in [(400, 600), (800, 500)] {
            let deviceItems = try continuousItems(in: EPUBScrollDocument.options(
                "{\"width\":\(width),\"height\":\(height)}", publication: deviceBook,
                index: 0, handler: deviceHandler))
            if width == 400 { XCTAssertEqual(deviceItems[limit]["width"] as? Int, 1200) }
            XCTAssertEqual(deviceItems[limit + 1]["width"] as? Int, width)
            XCTAssertEqual(deviceItems[limit + 1]["height"] as? Int, height)
        }
    }

    func testOversizedZIPDimensionIsSkippedBeforeInflation() throws {
        let book = try budgetPublication(
            count: 2, chapter: dimensionChapter(
                bodyBytes: EPUBScrollDocument.maximumDimensionBytes + 1))
        var remaining = EPUBScrollDocument.maximumDimensionBytes
        XCTAssertNil(try book.fixedLayoutInfo(forSpineIndex: 0, remainingByteCount: &remaining))
        XCTAssertEqual(remaining, 0)
        XCTAssertNil(book.cachedFixedLayoutInfo(forSpineIndex: 0))
        // 後続 setup も通常の既定寸法を出せる。
        let items = try continuousItems(in: EPUBScrollDocument.options(
            "{}", publication: book, index: 0, handler: EPUBSchemeHandler(publication: book)))
        XCTAssertEqual(items.map { $0["width"] as? Int }, [1200, 1200])
    }

    func testRollImageSpineDimensionsStayExactWithinBudget() throws {
        // Corpus の lay-roll-images-in-spine(約 25.4 MiB)を上回る計 27 MiB。
        // ヘッダーだけを見る ImageIO 用に、有効な小画像の後ろへ余白を置く。
        var image = EPUBFixtures.tinyPNG
        image.append(Data(count: 3 * 1_024 * 1_024 - image.count))
        let book = try budgetPublication(count: 9, chapter: image, mediaType: "image/png")
        let items = try continuousItems(in: EPUBScrollDocument.options(
            "{}", publication: book, index: 0, handler: EPUBSchemeHandler(publication: book)))
        XCTAssertEqual(items.count, 9)
        XCTAssertTrue(items.allSatisfy { $0["width"] as? Int == 1 && $0["height"] as? Int == 1 })
    }

    func testOversizedReflowableGroupFallsBackToDocumentScroll() throws {
        let count = EPUBPublication.maximumEagerScrollItems + 1
        let book = try budgetPublication(count: count, layout: "reflowable")
        let handler = EPUBSchemeHandler(publication: book)
        for index in [0, count / 2, count - 1] {
            let json = EPUBScrollDocument.options(
                "{}", publication: book, index: index, handler: handler)
            let options = try decodeOptions(json)
            XCTAssertEqual(options["flow"] as? String, RenditionFlow.scrolledDoc.rawValue)
            let items = try continuousItems(in: json)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0]["index"] as? Int, index)
            XCTAssertEqual(items[0]["roll"] as? Bool, false)
            XCTAssertEqual(book.scrollGroup(containing: index), index..<(index + 1))
        }
    }

    func testReflowableGroupsThroughLimitKeepContinuousDisplay() throws {
        // 連続表示を宣言する Corpus の最大 9 項目と、上限ちょうどを確認する。
        for count in [9, EPUBPublication.maximumEagerScrollItems] {
            let book = try budgetPublication(count: count, layout: "reflowable")
            let json = EPUBScrollDocument.options(
                "{}", publication: book, index: count / 2,
                handler: EPUBSchemeHandler(publication: book))
            XCTAssertEqual(try decodeOptions(json)["flow"] as? String,
                           RenditionFlow.scrolledContinuous.rawValue)
            XCTAssertEqual(try continuousItems(in: json).count, count)
            XCTAssertEqual(book.scrollGroup(containing: count / 2), 0..<count)
        }
    }

    func testOversizedRollGroupFallsBackToDocumentScroll() throws {
        // 上限直後と実測された 200,000 項目の本で、roll も JSON を 1 件に抑える。
        for count in [EPUBPublication.maximumEagerScrollItems + 1, 200_000] {
            let book = try budgetPublication(count: count)
            let handler = EPUBSchemeHandler(publication: book)
            for index in [0, count / 2, count - 1] {
                let start = ContinuousClock.now
                let json = EPUBScrollDocument.options(
                    "{}", publication: book, index: index, handler: handler)
                let elapsed = ContinuousClock.now - start
                XCTAssertLessThan(elapsed, .seconds(1), "\(count) 項目の縮退 setup: \(elapsed)")
                if index == 0 { print("[Washi-1nm] \(count) roll items, fallback: \(elapsed)") }
                XCTAssertEqual(try decodeOptions(json)["flow"] as? String,
                               RenditionFlow.scrolledDoc.rawValue)
                let items = try continuousItems(in: json)
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items[0]["index"] as? Int, index)
                XCTAssertEqual(items[0]["roll"] as? Bool, true)
                XCTAssertEqual(book.scrollGroup(containing: index), index..<(index + 1))
            }
            // census 等が指定する単一項目は、巨大な roll 本でも正しい寸法を取得する。
            let json = EPUBScrollDocument.options(
                "{}", publication: book, index: count - 1, handler: handler, onlyItem: true)
            XCTAssertEqual(try decodeOptions(json)["flow"] as? String,
                           RenditionFlow.scrolledContinuous.rawValue)
            let items = try continuousItems(in: json)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0]["index"] as? Int, count - 1)
            XCTAssertEqual(items[0]["width"] as? Int, 600)
        }
    }

    func testRollGroupsThroughLimitKeepContinuousDisplay() throws {
        for count in [9, EPUBPublication.maximumEagerScrollItems] {
            let book = try budgetPublication(count: count)
            let json = EPUBScrollDocument.options(
                "{}", publication: book, index: count / 2,
                handler: EPUBSchemeHandler(publication: book))
            XCTAssertEqual(try decodeOptions(json)["flow"] as? String,
                           RenditionFlow.scrolledContinuous.rawValue)
            let items = try continuousItems(in: json)
            XCTAssertEqual(items.count, count)
            XCTAssertTrue(items.allSatisfy { $0["roll"] as? Bool == true })
            XCTAssertEqual(book.scrollGroup(containing: count / 2), 0..<count)
        }
    }

    func testMixedOversizedGroupAlsoFallsBackAndOnlyItemStaysBounded() throws {
        // roll が多くても非 roll が 1 件あれば JS は全件先読みする。
        let count = EPUBPublication.maximumEagerScrollItems + 1
        let book = try budgetPublication(count: count, layout: "reflowable", mixed: true)
        let handler = EPUBSchemeHandler(publication: book)
        for index in [0, count - 1] {
            let options = try decodeOptions(EPUBScrollDocument.options(
                "{}", publication: book, index: index, handler: handler))
            XCTAssertEqual(options["flow"] as? String, RenditionFlow.scrolledDoc.rawValue)
            XCTAssertEqual((options["continuousItems"] as? [[String: Any]])?.count, 1)
        }
        let roll = try budgetPublication(count: count)
        let items = try continuousItems(in: EPUBScrollDocument.options(
            "{}", publication: roll, index: count - 1,
            handler: EPUBSchemeHandler(publication: roll), onlyItem: true))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["index"] as? Int, count - 1)
        XCTAssertEqual(items[0]["width"] as? Int, 600)
    }

    private func decodeOptions(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func continuousItems(in json: String) throws -> [[String: Any]] {
        try XCTUnwrap(decodeOptions(json)["continuousItems"] as? [[String: Any]])
    }

    private func dimensionChapter(bodyBytes: Int = 0,
                                  viewport: String = "width=600,height=900") -> Data {
        Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="viewport" content="\(viewport)"/></head>
        <body><p>\(String(repeating: "x", count: bodyBytes))</p></body></html>
        """.utf8)
    }

    private func budgetPublication(count: Int, layout: String = "roll",
                                   chapter: Data? = nil, mixed: Bool = false,
                                   mediaType: String = "application/xhtml+xml") throws -> EPUBPublication {
        let spine = (0..<count).map { index in
            let properties = mixed && index < count - 1 ? "rendition:layout-pre-paginated" : ""
            return "<itemref idref=\"page\" properties=\"\(properties)\"/>"
        }.joined()
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">scroll-budget</dc:identifier><dc:title>予算</dc:title><dc:language>ja</dc:language>
        <meta property="rendition:layout">\(layout)</meta>
        <meta property="rendition:flow">scrolled-continuous</meta></metadata>
        <manifest><item id="page" href="page.xhtml" media-type="\(mediaType)"/></manifest>
        <spine>\(spine)</spine></package>
        """
        return try EPUBFixtures.publication([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/page.xhtml", chapter ?? dimensionChapter())
        ], name: "scroll-budget", method: 8)
    }
}
