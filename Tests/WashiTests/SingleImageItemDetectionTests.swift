import Foundation
import XCTest
@testable import WashiCore

// 画像 1 枚だけの項目の判定(Washi-uwq)。画像要素の名前が現れない章は XML の
// 解析を省くが、判定の結果は fixedLayoutInfo の simpleImagePath と変わらない。

final class SingleImageItemDetectionTests: XCTestCase {
    private func xhtml(_ body: String, encoding: String = "UTF-8") -> String {
        "<?xml version=\"1.0\" encoding=\"\(encoding)\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\""
            + " xmlns:svg=\"http://www.w3.org/2000/svg\""
            + " xmlns:xlink=\"http://www.w3.org/1999/xlink\" xml:lang=\"ja\">"
            + "<head><title>t</title></head><body>" + body + "</body></html>"
    }

    /// 項目ごとの文書データを、この順の spine に並べた本を作る
    private func makeBook(_ documents: [Data]) throws -> EPUBPublication {
        var manifest = ""
        var spine = ""
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/images/page.png", EPUBFixtures.tinyPNG),
        ]
        for (index, document) in documents.enumerated() {
            manifest += "<item id=\"c\(index)\" href=\"text/c\(index).xhtml\" "
                + "media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(index)\"/>"
            entries.append(("OEBPS/text/c\(index).xhtml", document))
        }
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
            unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:single-image-detection</dc:identifier>
                <dc:title>Single-image detection</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-25T00:00:00Z</meta>
              </metadata>
              <manifest>\(manifest)<item id="image" href="images/page.png" \
            media-type="image/png"/></manifest>
              <spine>\(spine)</spine>
            </package>
            """
        entries.append(("OEBPS/package.opf", Data(opf.utf8)))
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-single-image-detection.epub"))
    }

    func testImageElementNamesAreFoundInASCIICompatibleBytes() {
        XCTAssertFalse(EPUBPublication.mayContainImageElement(
            Data(xhtml("<p>本文だけの章</p>").utf8)))
        XCTAssertFalse(EPUBPublication.mayContainImageElement(Data()))
        XCTAssertTrue(EPUBPublication.mayContainImageElement(
            Data(xhtml("<img src=\"a.png\"/>").utf8)))
        XCTAssertTrue(EPUBPublication.mayContainImageElement(
            Data(xhtml("<svg:svg><svg:image xlink:href=\"a.png\"/></svg:svg>").utf8)))
    }

    /// UTF-16 では要素名が ASCII のバイト列にならないので、解析を省かない
    func testUTF16DocumentsAreNeverSkipped() throws {
        let text = xhtml("<p>text</p>", encoding: "UTF-16")
        let littleEndian = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        let bigEndian = try XCTUnwrap(text.data(using: .utf16BigEndian))
        XCTAssertTrue(EPUBPublication.mayContainImageElement(Data([0xFF, 0xFE]) + littleEndian))
        XCTAssertTrue(EPUBPublication.mayContainImageElement(Data([0xFE, 0xFF]) + bigEndian))
        XCTAssertTrue(EPUBPublication.mayContainImageElement(littleEndian))
    }

    /// 解析を省く章も省かない章も、fixedLayoutInfo と同じ答えになる
    func testDetectionMatchesFixedLayoutInfo() throws {
        let image = "<img src=\"../images/page.png\"/>"
        let utf16Image = xhtml(image, encoding: "UTF-16")
        let cases: [(document: Data, expected: Bool?)] = [
            (Data(xhtml(image).utf8), true),
            // 文字だけの大きな章(解析を省く)
            (Data(xhtml("<p>" + String(repeating: "本文", count: 5_000) + "</p>").utf8), false),
            // 挿絵を含む文字の章
            (Data(xhtml("<p>挿絵つき</p>" + image).utf8), false),
            // 名前は現れるが画像要素は無い
            (Data(xhtml("<p>image という語だけ</p>").utf8), false),
            (Data(xhtml("<div><svg:svg viewBox=\"0 0 10 10\">"
                        + "<svg:image xlink:href=\"../images/page.png\"/>"
                        + "</svg:svg></div>").utf8), nil),
            (Data([0xFF, 0xFE]) + (utf16Image.data(using: .utf16LittleEndian) ?? Data()), nil),
        ]
        let book = try makeBook(cases.map { $0.document })
        for (index, item) in cases.enumerated() {
            let reference = (try? book.fixedLayoutInfo(forSpineIndex: index))?
                .simpleImagePath != nil
            XCTAssertEqual(book.isSingleImageItem(atSpineIndex: index), reference,
                           "item \(index)")
            if let expected = item.expected {
                XCTAssertEqual(reference, expected, "item \(index)")
            }
        }
    }
}
