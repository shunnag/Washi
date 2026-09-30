import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C52: 読書位置・しおりのテキストアンカー。
/// 進行率だけの復元は font 倍率や画面幅が変わると数ページずれるため、
/// 画面先頭の文字の抽出本文位置を併記して同じ文へ戻す。
final class TextAnchorLocatorTests: XCTestCase {
    func testLocatorCarriesAnchorThroughCoding() throws {
        let locator = EPUBLocator(spineIndex: 3, progression: 0.42,
                                  idref: "chap4", textOffset: 12_345)
        let data = try JSONEncoder().encode(locator)
        let decoded = try JSONDecoder().decode(EPUBLocator.self, from: data)
        XCTAssertEqual(decoded, locator)
        XCTAssertEqual(decoded.textOffset, 12_345)
    }

    /// アンカーを持たない旧い保存データはそのまま読める(進行率で復元する)
    func testOldSavedLocatorDecodesWithoutAnchor() throws {
        let json = Data("""
            {"spineIndex":2,"progression":0.5,"idref":"c3"}
            """.utf8)
        let decoded = try JSONDecoder().decode(EPUBLocator.self, from: json)
        XCTAssertEqual(decoded.spineIndex, 2)
        XCTAssertNil(decoded.textOffset)
    }

    /// 壊れた値(負数)はアンカー無しとして扱う
    func testNegativeAnchorIsIgnored() throws {
        let json = Data("""
            {"spineIndex":0,"progression":0,"textOffset":-5}
            """.utf8)
        XCTAssertNil(try JSONDecoder().decode(EPUBLocator.self, from: json).textOffset)
        XCTAssertNil(EPUBLocator(spineIndex: 0, textOffset: -1).textOffset)
    }

    /// アンカーは等価性に含まれる(別位置として保存できる)
    func testAnchorParticipatesInEquality() {
        let a = EPUBLocator(spineIndex: 1, progression: 0.5, textOffset: 10)
        let b = EPUBLocator(spineIndex: 1, progression: 0.5, textOffset: 99)
        let c = EPUBLocator(spineIndex: 1, progression: 0.5)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
