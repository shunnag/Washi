import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C40: 保存済みハイライトの描画。
final class HighlightModelTests: XCTestCase {
    func testCodingRoundTrip() throws {
        let highlight = EPUBHighlight(id: "h1", spineIndex: 2, idref: "c3",
                                      utf16Offset: 100, utf16Length: 25,
                                      style: .green, note: "覚え書き")
        let data = try JSONEncoder().encode(highlight)
        let decoded = try JSONDecoder().decode(EPUBHighlight.self, from: data)
        XCTAssertEqual(decoded, highlight)
        XCTAssertEqual(decoded.note, "覚え書き")
        XCTAssertEqual(decoded.textRange.utf16Offset, 100)
    }

    /// 壊れた保存データを持ち込ませない
    func testDecodingClampsBadValues() throws {
        let json = Data("""
            {"id":"x","spineIndex":0,"utf16Offset":-5,"utf16Length":0,"style":"chartreuse"}
            """.utf8)
        let decoded = try JSONDecoder().decode(EPUBHighlight.self, from: json)
        XCTAssertEqual(decoded.utf16Offset, 0)
        XCTAssertEqual(decoded.utf16Length, 1)
        XCTAssertEqual(decoded.style, .yellow, "未知の見た目は既定へ落とす")
    }

    func testInitializerClampsBadValues() {
        let highlight = EPUBHighlight(id: "x", spineIndex: 0,
                                      utf16Offset: -3, utf16Length: -1)
        XCTAssertEqual(highlight.utf16Offset, 0)
        XCTAssertEqual(highlight.utf16Length, 1)
    }
}
