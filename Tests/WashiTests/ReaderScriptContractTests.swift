import Foundation
import XCTest
@testable import Washi
@testable import WashiCore

/// Swift 側の契約(EPUBScriptMessage ほか)と注入 JS の文字列が同期している
/// ことを WebKit なしで検証する。片側だけに種別や鍵を足すとここで落ちる。
final class ReaderScriptContractTests: XCTestCase {
    private typealias Script = (name: String, source: String)

    private static let scripts: [Script] = [
        ("pageScript", ReaderScripts.pageScript),
        ("continuousScrollScript", ReaderScripts.continuousScrollScript),
    ]

    private static let messageTypes = Set(EPUBScriptMessage.allCases.map(\.rawValue))
    private static let resultKeys = Set(EPUBScriptSetupResultKey.allCases.map(\.rawValue))
    private static let optionKeys = Set(EPUBScriptSetupOptionKey.allCases.map(\.rawValue))

    // MARK: - 補助

    /// pattern の最初のキャプチャを全て集める。
    private func captures(_ pattern: String, in source: String) throws -> [String] {
        let regex = try Regex(pattern)
        return source.matches(of: regex).compactMap { match in
            match.output[1].substring.map(String.init)
        }
    }

    /// `function <name>(` の後にある最初の `return` に続くオブジェクトリテラルを、
    /// 波括弧の対応を数えて切り出す(`return {` でも `return Object.assign({` でも同じ)。
    private func returnedObjectLiteral(ofFunction name: String,
                                       in source: String) throws -> Substring {
        let function = try XCTUnwrap(source.range(of: "function \(name)("),
                                     "function \(name) がない")
        let returnKeyword = try XCTUnwrap(
            source.range(of: "return", range: function.upperBound..<source.endIndex),
            "\(name) に return がない")
        let open = try XCTUnwrap(source[returnKeyword.upperBound...].firstIndex(of: "{"),
                                 "\(name) の return がオブジェクトを返していない")
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return source[open...index] }
            default: break
            }
            index = source.index(after: index)
        }
        XCTFail("\(name) のオブジェクトリテラルが閉じていない")
        return source[open...]
    }

    /// オブジェクトリテラル直下の鍵(`{` または `,` の直後の識別子)。
    private func keys(ofObjectLiteral literal: Substring) throws -> Set<String> {
        Set(try captures(#"(?:\{|,)\s*(\w+)\s*:"#, in: String(literal)))
    }

    // MARK: - メッセージ種別

    func testPostedMessageTypesMatchEnum() throws {
        var posted = Set<String>()
        for script in Self.scripts {
            let types = Set(try captures(#"\btype:\s*'(\w+)'"#, in: script.source))
            XCTAssertFalse(types.isEmpty, "\(script.name) がメッセージを post していない")
            posted.formUnion(types)
        }
        XCTAssertEqual(posted, Self.messageTypes,
                       "JS が post する type と EPUBScriptMessage が食い違う: "
                       + "JS だけ \(posted.subtracting(Self.messageTypes).sorted()) / "
                       + "Swift だけ \(Self.messageTypes.subtracting(posted).sorted())")
    }

    // MARK: - setup の戻り値と引数

    func testSetupResultKeysMatchEnum() throws {
        for script in Self.scripts {
            let literal = try returnedObjectLiteral(ofFunction: "setupResult",
                                                    in: script.source)
            let found = try keys(ofObjectLiteral: literal)
            XCTAssertEqual(found, Self.resultKeys,
                           "\(script.name) の setupResult の鍵が EPUBScriptSetupResultKey と食い違う: "
                           + "JS だけ \(found.subtracting(Self.resultKeys).sorted()) / "
                           + "Swift だけ \(Self.resultKeys.subtracting(found).sorted())")
        }
    }

    /// FXL などが setupResult に渡す上書きも、宣言済みの鍵しか使わない。
    func testSetupResultOverridesUseDeclaredKeys() throws {
        let overrides = try captures(#"setupResult\((?:true|false),\s*(\{[^}]*\})"#,
                                     in: ReaderScripts.pageScript)
        XCTAssertFalse(overrides.isEmpty, "FXL 経路の上書きが見つからない")
        for literal in overrides {
            let found = try keys(ofObjectLiteral: Substring(literal))
            XCTAssertTrue(found.isSubset(of: Self.resultKeys),
                          "未宣言の鍵 \(found.subtracting(Self.resultKeys).sorted()) を上書きしている")
        }
    }

    func testSetupOptionReadsAreDeclared() throws {
        var reads = Set<String>()
        for script in Self.scripts {
            reads.formUnion(try captures(#"\boptions\.(\w+)"#, in: script.source))
        }
        // 連続スクロール文書は setup(next) / repaginate(next) の引数からも読む。
        reads.formUnion(try captures(#"\bnext\.(\w+)"#,
                                     in: ReaderScripts.continuousScrollScript))
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.isSubset(of: Self.optionKeys),
                      "EPUBScriptSetupOptionKey にない鍵を読んでいる: "
                      + "\(reads.subtracting(Self.optionKeys).sorted())")
    }

    // MARK: - WashiCore との共有

    /// 本文地図が飛ばす要素名は WashiCore の本文抽出と同じ集合でなければならない。
    func testTextMapSkippedElementsMatchWashiCore() throws {
        let source = ReaderScripts.pageScript
        let start = try XCTUnwrap(source.range(of: "const skipped = {"))
        let end = try XCTUnwrap(source.range(of: "};", range: start.upperBound..<source.endIndex))
        let names = Set(try captures(#"'([\w-]+)'"#, in: String(source[start.lowerBound..<end.upperBound])))
        XCTAssertEqual(names, XMLElement.readableTextSkippedElementNames)
    }

    // MARK: - 基礎 CSS の埋め込み

    /// baseCSSInjector は baseCSS を JSON としても読める文字列リテラルで埋め込む。
    func testBaseCSSInjectorEmbedsBaseCSSAsStringLiteral() throws {
        let embedded = ReaderScripts.jsStringLiteral(ReaderScripts.baseCSS)
        XCTAssertTrue(ReaderScripts.baseCSSInjector.contains("el.textContent = \(embedded);"))
        let hostile = "a\\b \"q\" `t` ${x}\n\r\t\u{2028}\u{2029}\u{1}日本語"
        for sample in [ReaderScripts.baseCSS, hostile] {
            let literal = ReaderScripts.jsStringLiteral(sample)
            XCTAssertFalse(literal.contains { $0.isNewline }, "行終端子が生のまま残っている")
            let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
            XCTAssertEqual(decoded?.first, sample)
        }
    }

    // MARK: - 既存テストが頼る足場

    /// ReaderScriptsRenderingLifecycleTests はこの 1 行を置換して非公開関数へ入る。
    func testPageScriptKeepsWashiExportAnchor() {
        let anchor = "window.__washi = washi;"
        XCTAssertEqual(ReaderScripts.pageScript.components(separatedBy: anchor).count - 1, 1)
    }
}
