import AppKit
import Foundation
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C42: WebKit に別名の無い -epub- 接頭辞 CSS の補完。
/// 対象は macOS 26 / WebKit の実測で解釈されなかった 6 プロパティ。
final class PrefixedCSSPolyfillTests: XCTestCase {
    func testAddsStandardDeclarationKeepingOriginal() {
        let css = ".tcy { -epub-text-combine-horizontal: all; }"
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("-epub-text-combine-horizontal: all"))
        XCTAssertTrue(out.contains("text-combine-upright: all"), out)
    }

    func testHandlesDeclarationWithoutTrailingSemicolon() {
        let css = "p { -epub-line-break: strict }"
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("line-break: strict"), out)
        XCTAssertTrue(out.hasSuffix("}"), out)
    }

    func testKeepsImportantAndMultipleDeclarations() {
        let css = """
            .a { -epub-text-align-last: center !important; color: red; }
            .b { -epub-ruby-position: under; }
            """
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("text-align-last: center !important"), out)
        XCTAssertTrue(out.contains("ruby-position: under"), out)
        XCTAssertTrue(out.contains("color: red"), out)
    }

    /// WebKit が解釈するものは触らない(二重宣言を増やさない)
    func testLeavesSupportedPrefixedPropertiesAlone() {
        let css = "p { -epub-writing-mode: vertical-rl; -epub-word-break: break-all; }"
        XCTAssertEqual(EPUBPrefixedCSS.polyfilled(css), css)
    }

    /// 名前の一部に一致するだけの綴りへ誤爆しない
    func testDoesNotMatchLongerPropertyNames() {
        let css = "p { -epub-line-breaking: strict; }"
        XCTAssertEqual(EPUBPrefixedCSS.polyfilled(css), css)
    }

    func testNonCSSDataIsUntouched() {
        let data = Data("body{color:#000}".utf8)
        XCTAssertEqual(EPUBPrefixedCSS.polyfilledStylesheet(data), data)
    }

    func testTruncatedPropertyWithTrailingWhitespaceDoesNotCrash() {
        for (prefixed, _) in EPUBPrefixedCSS.unsupported {
            for whitespace in ["", " ", "   ", "\t\n"] {
                let css = "p { \(prefixed)\(whitespace)"
                XCTAssertEqual(EPUBPrefixedCSS.polyfilled(css), css)
            }
        }
    }

    func testPreservesCommentsStringsURLsAndSupportsConditions() {
        for css in [
            "/* -epub-line-break: strict */ p { color: red; }",
            "p::before { content: '-epub-line-break: strict'; }",
            "p { background: url(data:text/plain,-epub-line-break:strict); }",
            "[data-example='-epub-line-break:strict'] { color: red; }",
            "@supports (-epub-line-break: strict) { p { color: red; } }",
            "p { --example: { -epub-line-break: strict }; }",
        ] {
            XCTAssertEqual(EPUBPrefixedCSS.polyfilled(css), css)
        }
    }

    func testHandlesCommentsAndCSSWhitespaceAroundColon() {
        let css = "@media print { p { -epub-line-break\t/* mode */\n: strict; } }"
        XCTAssertTrue(EPUBPrefixedCSS.polyfilled(css).contains("; line-break: strict;"))
    }

    func testPropertyNamesAreASCIICaseInsensitive() {
        XCTAssertEqual(EPUBPrefixedCSS.polyfilled("p { -EPUB-LINE-BREAK: strict }"),
                       "p { -EPUB-LINE-BREAK: strict ; line-break: strict}")
    }

    func testPreservesNestedValueAndQuotedDelimiters() {
        let css = "p { -epub-line-break: var(--mode, 'a;}'); color: red; }"
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("; line-break: var(--mode, 'a;}'); color: red;"), out)
    }
}
