import CoreGraphics
import ImageIO
import XCTest
@testable import Washi
@testable import WashiCore

/// 固定レイアウトの情報(viewport・単一画像・SVG ラッパー)と、fallback 連鎖の
/// 描画先・spine 番号の解決
final class FixedLayoutInfoTests: XCTestCase {
    private func openFXLComic() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries()),
            displayURL: URL(fileURLWithPath: "/tmp/comic.epub"))
    }

    func testFixedLayoutInfo() throws {
        let publication = try openFXLComic()
        XCTAssertTrue(publication.isFixedLayout)
        XCTAssertEqual(publication.readingDirection, .rtl)

        let page1 = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertEqual(page1.viewportSize, CGSize(width: 1200, height: 1920))
        XCTAssertEqual(page1.simpleImagePath, "OEBPS/images/p001.png")
        XCTAssertEqual(page1.pageSpread, .center)

        let page2 = try publication.fixedLayoutInfo(forSpineIndex: 1)
        XCTAssertEqual(page2.pageSpread, .left)
        let page3 = try publication.fixedLayoutInfo(forSpineIndex: 2)
        XCTAssertEqual(page3.pageSpread, .right)
    }

    /// 電書協 FXL テンプレートの SVG ラッパー形式でも画像を直接取り出せる
    func testSVGWrappedImagePage() throws {
        let svgPage = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="UTF-8"/><title>p</title>
        <meta name="viewport" content="width=848, height=1200"/></head>
        <body epub:type="cover"><div class="main">
          <svg xmlns="http://www.w3.org/2000/svg" version="1.1"
               xmlns:xlink="http://www.w3.org/1999/xlink"
               width="100%" height="100%" viewBox="0 0 848 1200">
            <image width="848" height="1200" xlink:href="images/p001.png"/>
          </svg>
        </div></body></html>
        """
        var entries = EPUBFixtures.fxlComicEntries()
        entries[4] = ("OEBPS/p001.xhtml", Data(svgPage.utf8))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/comic.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertEqual(info.viewportSize, CGSize(width: 848, height: 1200))
        XCTAssertEqual(info.simpleImagePath, "OEBPS/images/p001.png")
    }

    /// viewport の寛容パース("500px" → 500 の数値サルベージ)
    func testViewportSalvage() {
        XCTAssertEqual(
            EPUBPublication.parseViewportContent("width=500px, height=700px"),
            CGSize(width: 500, height: 700))
        XCTAssertEqual(
            EPUBPublication.parseViewportContent("width = 848 , height = 1200"),
            CGSize(width: 848, height: 1200))
        XCTAssertNil(EPUBPublication.parseViewportContent(
            "width=device-width, initial-scale=1"))
    }

    // cooViewer-oxr.50: 数値 viewport を持てない device-* 指定も、欠落とは
    // 区別して表示先サイズへ追従できることを検証する。
    func testDeviceSizedViewportVariantsArePreserved() throws {
        let contents = [
            "width=device-width",
            "width=848, height=device-height",
            "width=device-width, height=device-height, initial-scale=1.0",
        ]
        for (index, content) in contents.enumerated() {
            let xhtml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head>
                  <meta name="viewport" content="\(content)"/>
                </head><body><p>page</p></body></html>
                """
            let publication = try makeSingleSpinePublication(
                item: "<item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/>",
                resourcePath: "OEBPS/page.xhtml", data: Data(xhtml.utf8))
            let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
            XCTAssertNil(info.viewportSize, "variant \(index)")
            XCTAssertTrue(info.viewportIsDeviceSized, "variant \(index)")
        }
    }

    // cooViewer-oxr.91: SVG spine の単一 image と viewBox を直接表示用に解決する。
    func testSVGSpineSingleImageUsesResolvedImage() throws {
        let svg = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg"
                 xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 848 1200">
              <title>page</title><desc>single image page</desc>
              <defs><style>.page { opacity: 1 }</style></defs><metadata>ignored</metadata>
              <image class="page" width="848" height="1200"
                     xlink:href="images/page.png"/>
            </svg>
            """
        let publication = try makeSVGSpinePublication(svg)
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertEqual(info.viewportSize, CGSize(width: 848, height: 1200))
        XCTAssertEqual(info.simpleImagePath, "OEBPS/images/page.png")
    }

    // cooViewer-oxr.91: 可視テキストを含む SVG は画像だけのページではない。
    func testSVGSpineWithTextDoesNotUseSimpleImage() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800">
              <image href="images/page.png"/><text>caption</text>
            </svg>
            """
        let info = try makeSVGSpinePublication(svg)
            .fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertNil(info.simpleImagePath)
    }

    // cooViewer-oxr.91: 複数 image を合成する SVG は直接画像化しない。
    func testSVGSpineWithTwoImagesDoesNotUseSimpleImage() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800">
              <image href="images/page.png"/><image href="images/page.png"/>
            </svg>
            """
        let info = try makeSVGSpinePublication(svg)
            .fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertNil(info.simpleImagePath)
    }

    // cooViewer-oxr.15: image/* 自身が spine の場合はそのパスと ImageIO の
    // 画素寸法を返し、XML として本文解析しない。
    func testJPEGSpineUsesOwnPathAndPixelDimensions() throws {
        let jpeg = try makeJPEG(width: 12, height: 18)
        let publication = try makeSingleSpinePublication(
            item: "<item id=\"page\" href=\"images/page.jpg\" media-type=\"image/jpeg\"/>",
            resourcePath: "OEBPS/images/page.jpg", data: jpeg)
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertEqual(info.simpleImagePath, "OEBPS/images/page.jpg")
        XCTAssertEqual(info.viewportSize, CGSize(width: 12, height: 18))
        XCTAssertFalse(info.viewportIsDeviceSized)
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0), "")
    }

    // cooViewer-oxr.16: W3C の foreign JSON/XML と欠落 image spine の形で、
    // 宣言元を保持しながら実在 XHTML fallback を表示・本文抽出に使う。
    func testReadingOrderResolvesRenderableExistingFallbacks() throws {
        let manifest = """
            <item id="json" href="foreign/page.json" media-type="application/json" fallback="json-doc"/>
            <item id="json-doc" href="text/json.xhtml" media-type="application/xhtml+xml"/>
            <item id="xml" href="foreign/page.xml" media-type="application/xml" fallback="xml-doc"/>
            <item id="xml-doc" href="text/xml.xhtml" media-type="application/xhtml+xml"/>
            <item id="missing-image" href="images/missing.jpg" media-type="image/jpeg" fallback="image-doc"/>
            <item id="image-doc" href="text/image.xhtml" media-type="application/xhtml+xml"/>
            """
        let spine = """
            <itemref idref="json"/><itemref idref="xml"/>
            <itemref idref="missing-image"/>
            """
        let publication = try makePublication(
            manifest: manifest, spine: spine,
            resources: [
                ("OEBPS/foreign/page.json", Data("{}".utf8)),
                ("OEBPS/foreign/page.xml", Data("<foreign/>".utf8)),
                ("OEBPS/text/json.xhtml", Data(EPUBFixtures.chapterXHTML(
                    title: "json", body: "<p>JSON fallback text</p>").utf8)),
                ("OEBPS/text/xml.xhtml", Data(EPUBFixtures.chapterXHTML(
                    title: "xml", body: "<p>XML fallback text</p>").utf8)),
                ("OEBPS/text/image.xhtml", Data(EPUBFixtures.chapterXHTML(
                    title: "image", body: "<p>Image fallback text</p>").utf8)),
            ])

        XCTAssertEqual(publication.readingOrder.map(\.item.id),
                       ["json", "xml", "missing-image"])
        XCTAssertEqual(publication.readingOrder.map(\.containerPath), [
            "OEBPS/foreign/page.json", "OEBPS/foreign/page.xml",
            "OEBPS/images/missing.jpg",
        ])
        XCTAssertEqual(publication.readingOrder.map(\.resolvedItem.id),
                       ["json-doc", "xml-doc", "image-doc"])
        XCTAssertEqual(publication.readingOrder.map(\.resolvedContainerPath), [
            "OEBPS/text/json.xhtml", "OEBPS/text/xml.xhtml",
            "OEBPS/text/image.xhtml",
        ])
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0),
                       "JSON fallback text")
        XCTAssertEqual(try publication.extractText(forSpineIndex: 1),
                       "XML fallback text")
        XCTAssertEqual(try publication.extractText(forSpineIndex: 2),
                       "Image fallback text")
        XCTAssertNoThrow(try publication.fixedLayoutInfo(forSpineIndex: 2))
    }

    /// 宣言画像を描画できる場合も、中間・終端の fallback 文書を同じ spine に結ぶ。
    func testSpineIndexResolvesEveryFallbackChainMember() throws {
        let publication = try makePublication(
            manifest: """
                <item id="page" href="images/page.png" media-type="image/png" fallback="foreign"/>
                <item id="foreign" href="foreign/page.json" media-type="application/json" fallback="doc"/>
                <item id="doc" href="text/fallback.xhtml" media-type="application/xhtml+xml" fallback="tail"/>
                <item id="tail" href="text/last%20page.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                """,
            spine: "<itemref idref=\"page\"/>",
            resources: [
                ("OEBPS/images/page.png", EPUBFixtures.tinyPNG),
                ("OEBPS/foreign/page.json", Data("{}".utf8)),
                ("OEBPS/text/fallback.xhtml", Data(EPUBFixtures.chapterXHTML(
                    title: "代替本文", body: "<p id=\"target\">本文</p>").utf8)),
                ("OEBPS/text/last page.xhtml", Data(EPUBFixtures.chapterXHTML(
                    title: "最終代替", body: "<p>本文</p>").utf8)),
                ("OEBPS/nav.xhtml", Data("""
                    <html xmlns="http://www.w3.org/1999/xhtml"
                          xmlns:epub="http://www.idpf.org/2007/ops"><body>
                      <nav epub:type="toc"><ol>
                        <li><a href="text/fallback.xhtml#target">代替本文の章</a></li>
                      </ol></nav>
                    </body></html>
                    """.utf8)),
            ])
        let entry = try XCTUnwrap(publication.readingOrder.first)
        XCTAssertEqual(entry.resolvedItem.id, "page")
        XCTAssertEqual(publication.fallbackChain(for: entry.item).map(\.id),
                       ["page", "foreign", "doc", "tail"])
        for href in ["images/page.png", "foreign/page.json",
                     "text/fallback.xhtml", "text/last%20page.xhtml"] {
            let path = try XCTUnwrap(publication.containerPath(
                forHref: href, relativeTo: publication.package.path))
            XCTAssertEqual(publication.spineIndex(forContainerPath: path), 0, href)
            XCTAssertEqual(publication.spineIndex(forHref: href + "#target"), 0, href)
        }
        let navItem = try XCTUnwrap(publication.navigation.toc.first)
        XCTAssertEqual(publication.spineIndex(forNavItem: navItem), 0)
        XCTAssertEqual(publication.chapterTitle(forSpineIndex: 0), "代替本文の章")
    }

    /// 循環は打ち切り、共有する代替文書は文書順の先勝ちを維持する。
    /// 存在しない fallback ID から架空のパスを登録しない。
    func testFallbackSpineIndexHandlesCyclesSharedTargetsAndMissingIDs() throws {
        let publication = try makePublication(
            manifest: """
                <item id="first" href="first.png" media-type="image/png" fallback="shared"/>
                <item id="second" href="second.png" media-type="image/png" fallback="shared"/>
                <item id="shared" href="shared.xhtml" media-type="application/xhtml+xml" fallback="first"/>
                <item id="third" href="third.png" media-type="image/png" fallback="missing"/>
                """,
            spine: "<itemref idref=\"first\"/><itemref idref=\"second\"/><itemref idref=\"third\"/>",
            resources: [
                ("OEBPS/first.png", EPUBFixtures.tinyPNG),
                ("OEBPS/second.png", EPUBFixtures.tinyPNG),
                ("OEBPS/third.png", EPUBFixtures.tinyPNG),
                ("OEBPS/shared.xhtml", Data(EPUBFixtures.chapterXHTML(
                    title: "共有本文", body: "<p>本文</p>").utf8)),
            ])
        XCTAssertEqual(publication.spineIndex(forContainerPath: "OEBPS/first.png"), 0)
        XCTAssertEqual(publication.spineIndex(forContainerPath: "OEBPS/second.png"), 1)
        XCTAssertEqual(publication.spineIndex(forContainerPath: "OEBPS/shared.xhtml"), 0)
        XCTAssertEqual(publication.spineIndex(forContainerPath: "OEBPS/third.png"), 2)
        XCTAssertNil(publication.spineIndex(forContainerPath: "OEBPS/missing.xhtml"))
        XCTAssertEqual(publication.fallbackChain(for: publication.readingOrder[1].item)
            .map(\.id), ["second", "shared", "first"])
        XCTAssertEqual(publication.fallbackChain(for: publication.readingOrder[2].item)
            .map(\.id), ["third"])
    }

    private func makeSVGSpinePublication(_ svg: String) throws -> EPUBPublication {
        try makePublication(
            manifest: """
                <item id="page" href="page.svg" media-type="image/svg+xml"/>
                <item id="image" href="images/page.png" media-type="image/png"/>
                """,
            spine: "<itemref idref=\"page\"/>",
            resources: [
                ("OEBPS/page.svg", Data(svg.utf8)),
                ("OEBPS/images/page.png", EPUBFixtures.tinyPNG),
            ])
    }

    private func makeSingleSpinePublication(
        item: String, resourcePath: String, data: Data
    ) throws -> EPUBPublication {
        try makePublication(
            manifest: item, spine: "<itemref idref=\"page\"/>",
            resources: [(resourcePath, data)])
    }

    private func makePublication(
        manifest: String, spine: String,
        resources: [(name: String, data: Data)]
    ) throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:publication-resolution</dc:identifier>
                <dc:title>Publication resolution</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>\(manifest)</manifest><spine>\(spine)</spine>
            </package>
            """
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
        ]
        entries.append(contentsOf: resources)
        return try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/publication-resolution.epub"))
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
