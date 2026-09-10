import Foundation
import XCTest
@testable import WashiCore

/// cooViewer-oxr.10/11/89/92: 本文抽出と検索の追加仕様を検証する。
final class PublicationTestsTextExtractionSearch: XCTestCase {
    func testSearchSnippetRadiusAtIntegerLimits() throws {
        let publication = try makePublication(body: "<p>Before target after.</p>")
        XCTAssertEqual(publication.search("target", snippetRadius: Int.max).first?.snippet,
                       "Before target after.")
        XCTAssertEqual(publication.search("target", snippetRadius: Int.min).first?.snippet,
                       "target")
        XCTAssertEqual(publication.search("target", snippetRadius: 1).first?.snippet,
                       " target ")
    }

    /// cooViewer-oxr.11: 全角空白と NBSP を本文同様に畳んで検索する。
    func testSearchNormalizesIdeographicAndNonbreakingWhitespace() throws {
        let publication = try makePublication(
            body: "<p>字下げ\u{3000}本文\u{00A0}末尾\n改行検索</p>")

        XCTAssertEqual(publication.search("字下げ\u{3000}本文").count, 1)
        XCTAssertEqual(publication.search("本文\u{00A0}末尾").count, 1)
        XCTAssertEqual(publication.search("末尾\n改行検索").count, 1)
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0),
                       "字下げ 本文 末尾\n改行検索")
    }

    /// cooViewer-oxr.11: additive options が三種の比較感度を個別に制御する。
    func testSearchOptionsControlCaseDiacriticAndWidthSensitivity() throws {
        let publication = try makePublication(
            body: "<p>Map map café cafe Ｚ Z</p>")

        XCTAssertEqual(publication.search("Map").count, 2)
        XCTAssertEqual(publication.search(
            "Map", options: [.caseSensitive]).count, 1)
        XCTAssertEqual(publication.search("cafe").count, 2)
        XCTAssertEqual(publication.search(
            "cafe", options: [.diacriticSensitive]).count, 1)
        XCTAssertEqual(publication.search("Z").count, 2)
        XCTAssertEqual(publication.search(
            "Z", options: [.widthSensitive]).count, 1)
    }

    /// cooViewer-oxr.11: サロゲート対と結合文字より後でも UTF-16 範囲を返す。
    func testSearchHitCarriesUTF16RangeAfterSurrogateAndCombiningMark() throws {
        let publication = try makePublication(body: "<p>😀e\u{0301} 検索語</p>")
        let text = try publication.extractText(forSpineIndex: 0)
        let hit = try XCTUnwrap(publication.search("検索語").first)
        let match = try XCTUnwrap(text.range(of: "検索語"))
        let utf16Lower = try XCTUnwrap(match.lowerBound.samePosition(in: text.utf16))
        let utf16Upper = try XCTUnwrap(match.upperBound.samePosition(in: text.utf16))
        let expectedLower = text.utf16.distance(
            from: text.utf16.startIndex, to: utf16Lower)
        let expectedUpper = text.utf16.distance(
            from: text.utf16.startIndex, to: utf16Upper)

        XCTAssertEqual(hit.utf16Range, expectedLower..<expectedUpper)
        XCTAssertNotEqual(hit.characterOffset, hit.utf16Range.lowerBound)

        let legacy = EPUBSearchHit(spineIndex: 2, characterOffset: 3,
                                   length: 4, snippet: "legacy")
        XCTAssertEqual(legacy.utf16Range, 3..<7)
    }

    /// 半角ハングルの畳み込みで書記素数が減っても、後続の錨と抜粋は原文を指す。
    func testSearchOffsetsAfterWidthFoldingMergesGraphemes() throws {
        let fillers = String(repeating: "\u{FFA0}", count: 4)
        let publication = try makePublication(body: "<p>\(fillers)ABCDEFG</p>")
        let text = try publication.extractText(forSpineIndex: 0)

        for options: EPUBSearchOptions in [[], [.widthSensitive]] {
            let hit = try XCTUnwrap(publication.search(
                "ABCDEFG", options: options, snippetRadius: 1).first)
            XCTAssertEqual(hit.characterOffset, 4)
            XCTAssertEqual(hit.length, 7)
            XCTAssertEqual(hit.utf16Range, 4..<11)
            XCTAssertEqual(hit.snippet, "\u{FFA0}ABCDEFG")
            XCTAssertEqual((text as NSString).substring(with: NSRange(hit.utf16Range)),
                           "ABCDEFG")

            let tail = try XCTUnwrap(publication.search(
                "EFG", options: options, snippetRadius: 0).first)
            XCTAssertEqual(tail.characterOffset, 8)
            XCTAssertEqual(tail.utf16Range, 8..<11)
            XCTAssertEqual(tail.snippet, "EFG")
        }
    }

    /// 結合した書記素そのものを含む一致も、元の全文字を覆う範囲へ戻す。
    func testSearchRangeIncludesAllCharactersMergedByWidthFolding() throws {
        let fillers = String(repeating: "\u{FFA0}", count: 4)
        let foldedFillers = String(repeating: "\u{1160}", count: 4)
        XCTAssertEqual(fillers.count, 4)
        XCTAssertEqual(foldedFillers.count, 1)
        let publication = try makePublication(
            body: "<p>前\(fillers)ＡＢＣ後\(fillers)ＡＢＣ末</p>")

        // ハングルを含む章でも全半角を区別しない意味論を維持し、複数ヒットを戻す。
        try assertSearchRoundTrips(publication, query: foldedFillers + "ABC",
                                  options: [.diacriticSensitive],
                                  expectedSubstrings: [fillers + "ＡＢＣ", fillers + "ＡＢＣ"])
    }

    /// 全角英数字・半角濁点カナ・合成文字が混在しても、UTF-16 範囲で原文へ往復する。
    func testSearchMixedWidthJapaneseRangesRoundTrip() throws {
        let fillers = String(repeating: "\u{FFA0}", count: 4)
        let publication = try makePublication(
            body: "<p>前😀e\u{0301}\(fillers)ＡＢ１２ ｶﾞｷﾞ カ\u{3099} 後ＡＢ１２</p>")

        try assertSearchRoundTrips(publication, query: "ab12",
                                  expectedSubstrings: ["ＡＢ１２", "ＡＢ１２"])
        try assertSearchRoundTrips(publication, query: "ガギ",
                                  options: [.diacriticSensitive],
                                  expectedSubstrings: ["ｶﾞｷﾞ"])
        try assertSearchRoundTrips(publication, query: "ガ",
                                  options: [.diacriticSensitive],
                                  expectedSubstrings: ["ｶﾞ", "カ\u{3099}"])
        try assertSearchRoundTrips(publication, query: "é",
                                  options: [.diacriticSensitive],
                                  expectedSubstrings: ["e\u{0301}"])
    }

    /// 検索結果の UTF-16 範囲を保存済みハイライトへ渡しても、復元後の錨は原文を指す。
    func testSearchWidthFoldedHitSurvivesHighlightPersistence() throws {
        let fillers = String(repeating: "\u{FFA0}", count: 4)
        let publication = try makePublication(
            body: "<p>前😀e\u{0301}\(fillers)ｶﾞＡＢ後</p>")
        let text = try publication.extractText(forSpineIndex: 0)
        let hit = try XCTUnwrap(publication.search(
            "ガAB", options: [.diacriticSensitive], snippetRadius: 0).first)
        XCTAssertEqual(hit.characterOffset, 7)
        XCTAssertEqual(hit.length, 3)
        XCTAssertEqual(hit.utf16Range, 9..<13)

        let highlight = EPUBHighlight(
            id: "width-folded-hit", spineIndex: hit.spineIndex,
            utf16Offset: hit.utf16Range.lowerBound, utf16Length: hit.utf16Range.count)
        let saved = try JSONEncoder().encode(highlight)
        let restored = try JSONDecoder().decode(EPUBHighlight.self, from: saved)
        XCTAssertEqual(restored, highlight)
        let restoredRange = NSRange(location: restored.textRange.utf16Offset,
                                    length: restored.textRange.utf16Length)
        XCTAssertEqual(restoredRange, NSRange(location: 9, length: 4))
        XCTAssertEqual((text as NSString).substring(with: restoredRange), "ｶﾞＡＢ")
    }

    /// 畳み込みの有無や UTF-8 の粗い判定に関係なく、無ヒットは空配列を返す。
    func testSearchWithoutMatchesAcrossWidthFoldingPaths() throws {
        let texts = [
            "Plain English text. 😀 e\u{0301} ガ 日本語",
            "全角ＡＢ１２と半角ｶﾞ、合成カ\u{3099}、\u{FFA0}\u{FFA0}",
            // 異体字セレクタにも 0xEF があるが、全角/半角形には該当しない。
            "字\u{FE0F} 合成e\u{0301}",
        ]
        for text in texts {
            let publication = try makePublication(body: "<p>\(text)</p>")
            for rawValue in 0..<8 {
                let options = EPUBSearchOptions(rawValue: rawValue)
                for query in ["qzxqzx", "ＱＺＸＱＺＸ", "ｾﾞﾛﾋｯﾄ"] {
                    XCTAssertEqual(publication.search(query, options: options), [],
                                   "無ヒットの結果が変わった: \(text), \(query), \(rawValue)")
                }
            }
        }
    }

    /// 初ヒットの判定でも全比較オプションを守り、検索語だけの畳み込みも取りこぼさない。
    func testSearchFirstMatchPreservesAllSensitivityCombinations() throws {
        let cases: [(text: String, query: String, matched: String,
                     requiredInsensitivities: EPUBSearchOptions)] = [
            ("Café ガ", "café", "Café", [.caseSensitive]),
            ("Café ガ", "Cafe", "Café", [.diacriticSensitive]),
            ("Café ガ", "Ｃafé", "Café", [.widthSensitive]),
            ("Café ガ", "ｶﾞ", "ガ", [.widthSensitive]),
            ("Ｃafé ｶﾞ", "Café", "Ｃafé", [.widthSensitive]),
            ("Ｃafé ｶﾞ", "ガ", "ｶﾞ", [.widthSensitive]),
            ("Ｃafé ｶﾞ", "cafe", "Ｃafé", [.caseSensitive, .diacriticSensitive, .widthSensitive]),
            ("字\u{FE0F} Café ガ", "Ｃafe", "Café", [.diacriticSensitive, .widthSensitive]),
        ]
        for testCase in cases {
            let publication = try makePublication(body: "<p>\(testCase.text)</p>")
            for rawValue in 0..<8 {
                let options = EPUBSearchOptions(rawValue: rawValue)
                let shouldMatch = options.intersection(testCase.requiredInsensitivities).isEmpty
                try assertSearchRoundTrips(publication, query: testCase.query, options: options,
                                          expectedSubstrings: shouldMatch ? [testCase.matched] : [])
            }
        }
    }

    /// cooViewer-oxr.89: SVG メタデータと MathML 注釈を捨て、可視 text は残す。
    func testExtractTextSkipsSVGMetadataAndMathMLAnnotations() throws {
        let body = """
            <p>前<svg xmlns="http://www.w3.org/2000/svg"><title>不可視題</title><desc>不可視説明</desc><text>SVG可視検索</text></svg><math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi><annotation>不可視注釈</annotation><annotation-xml><mtext>不可視XML</mtext></annotation-xml></math><title>HTML題</title><desc>HTML説明</desc><annotation>HTML注記</annotation><ruby>漢<rtc>kan</rtc></ruby>後</p>
            """
        let publication = try makePublication(body: body)
        let text = try publication.extractText(forSpineIndex: 0)

        XCTAssertEqual(text, "前SVG可視検索xHTML題HTML説明HTML注記漢後")
        XCTAssertFalse(text.contains("不可視"))
    }

    /// cooViewer-oxr.92: caption/th/td の境界で隣接文字列を分離する。
    func testExtractTextSeparatesCaptionAndTableCells() throws {
        let publication = try makePublication(body: """
            <table><caption>書誌</caption><tr><th>発行者</th><td>山田太郎</td></tr></table>
            """)

        XCTAssertEqual(try publication.extractText(forSpineIndex: 0),
                       "書誌\n発行者\n山田太郎")
    }

    /// cooViewer-oxr.10: XML 風バイトでも非内容文書の spine は解析しない。
    func testExtractTextSkipsXMLShapedUnsupportedSpineMedia() throws {
        let xmlShapedJSON = Data("""
            <?xml version="1.0"?><html><body><p>解析禁止</p></body></html>
            """.utf8)
        let publication = try makePublication(
            body: "", mediaType: "application/json", resourceData: xmlShapedJSON)

        XCTAssertEqual(try publication.extractText(forSpineIndex: 0), "")
    }

    /// 期待する原文から位置を独立に求め、文字単位と UTF-16 単位の両方で切り出す。
    private func assertSearchRoundTrips(
        _ publication: EPUBPublication,
        query: String,
        options: EPUBSearchOptions = [],
        expectedSubstrings: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let text = try publication.extractText(forSpineIndex: 0)
        let hits = publication.search(query, options: options, snippetRadius: 0)
        XCTAssertEqual(hits.count, expectedSubstrings.count, file: file, line: line)
        var searchStart = text.startIndex
        for (hit, expected) in zip(hits, expectedSubstrings) {
            let range = try XCTUnwrap(text.range(
                of: expected, options: .literal, range: searchStart..<text.endIndex),
                file: file, line: line)
            let expectedUTF16Range = NSRange(range, in: text)
            XCTAssertEqual(hit.characterOffset,
                           text.distance(from: text.startIndex, to: range.lowerBound),
                           file: file, line: line)
            XCTAssertEqual(hit.length, text.distance(from: range.lowerBound, to: range.upperBound),
                           file: file, line: line)
            XCTAssertEqual(NSRange(hit.utf16Range), expectedUTF16Range, file: file, line: line)
            XCTAssertEqual((text as NSString).substring(with: NSRange(hit.utf16Range)),
                           expected, file: file, line: line)
            XCTAssertEqual(String(text.dropFirst(hit.characterOffset).prefix(hit.length)),
                           expected, file: file, line: line)
            XCTAssertEqual(hit.snippet, expected, file: file, line: line)
            searchStart = range.upperBound
        }
    }

    private func makePublication(
        body: String,
        mediaType: String = "application/xhtml+xml",
        resourceData: Data? = nil
    ) throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:text-extraction-search</dc:identifier>
                <dc:title>Text extraction search</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-05T00:00:00Z</meta>
              </metadata>
              <manifest><item id="c" href="text/c.dat" media-type="\(mediaType)"/></manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>"
            + body + "</body></html>"
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/c.dat", resourceData ?? Data(xhtml.utf8)),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/text-extraction-search.epub"))
    }
}
