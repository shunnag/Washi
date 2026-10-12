import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// census は setup の pageCount しか読まないので、印刷ページ境界の走査
/// (DOM 全要素の querySelectorAll + getClientRects)を項目ごとの setup で省く。
/// 省く鍵は census が項目ごとの JSON に足すもので、cacheKey を成す基底 JSON
/// (= 中断の控え・キャッシュの索引)は 1 バイトも変わらない。ライブ表示の
/// setup / repaginate は従来どおり境界を収集する。
@MainActor
final class CensusPrintPageMarkerSkipTests: XCTestCase {
    private static let skipKey = EPUBScriptSetupOptionKey.skipPrintPageMarkers.rawValue

    private func json(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    /// 鍵(cacheKey = censusOptionsJSON)と setupPlan の出力には skip の鍵が無く、
    /// census が項目ごとに作る setup JSON だけがそれを持つ。
    func testCensusSetupJSONCarriesSkipFlagWhileKeyIsUnchanged() throws {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 800, height: 600), settings: settings)
        let key = metrics.censusOptionsJSON
        XCTAssertEqual(metrics.cacheKey, key)
        XCTAssertEqual(EPUBScreenMetrics.paginationVersion, 5)
        XCTAssertTrue(EPUBScreenMetrics.usesCurrentPaginationVersion(key))
        XCTAssertFalse(key.contains(Self.skipKey), "鍵に skip の鍵が混じってはならない")

        let plan = EPUBScreenMetrics.setupPlan(optionsJSON: key, applying: .auto)
        XCTAssertFalse(plan.optionsJSON.contains(Self.skipKey))

        let setupJSON = EPUBPaginationCensus.setupJSON(omittingPrintPageMarkers: plan.optionsJSON)
        let setup = try json(setupJSON)
        XCTAssertEqual(setup[Self.skipKey] as? Bool, true)
        var expected = try json(plan.optionsJSON)
        expected[Self.skipKey] = true
        XCTAssertEqual(setup as NSDictionary, expected as NSDictionary,
                       "項目ごとの setup JSON は plan + skip の鍵だけで、他の値は変わらない")
        // 鍵そのものは触っていない(同じ入力から同じ鍵)
        XCTAssertEqual(
            EPUBScreenMetrics(viewportSize: CGSize(width: 800, height: 600), settings: settings).cacheKey,
            key)
    }

    /// 壊れた JSON はそのまま返す(census は従来どおり setup を試みて JS 側で失敗する)。
    func testMalformedSetupJSONIsReturnedUnchanged() {
        XCTAssertEqual(EPUBPaginationCensus.setupJSON(omittingPrintPageMarkers: "not json"), "not json")
    }

    /// 実 WebKit: skip 付きの setup は DOM 全走査(querySelectorAll('*'))を 1 回も
    /// 行わず printPageMarkers を空で返し、pageCount は収集ありと同じ。鍵の無い
    /// 次の setup / repaginate(ライブ表示)は再び収集する。
    func testSetupWithSkipFlagReturnsNoMarkersAndSamePageCount() async throws {
        let body = """
            <style>
              .forced { display:block; break-before:column;
                        -webkit-column-break-before:always; height:1px; }
            </style>
            <span xmlns:epub="http://www.idpf.org/2007/ops" epub:type="pagebreak"
                  id="p1" title="1"></span><p>一ページ目。</p>
            <span class="forced pagebreak" id="p2" title="2"></span><p>二ページ目。</p>
            <span class="forced" role="doc-pagebreak" id="p3" aria-label="3"></span><p>三ページ目。</p>
            """
        let harness: ReaderScriptHarness
        do {
            harness = try ReaderScriptHarness(bodyHTML: body)
            try await harness.load()
        } catch {
            return try failOrSkipIfWebKitUnavailable()
        }
        defer { harness.close() }

        // labels は label を "," でつないだ文字列、scans は skip 付き setup 中の
        // querySelectorAll('*') の回数
        let result: [String: String] = try await harness.evaluate("""
            const options = {width:\(Int(harness.size.width)),height:\(Int(harness.size.height)),
                gap:0,spread:false,gutter:0,fixedLayout:false,keysEnabled:false,userCSS:''};
            const labels = r => r.printPageMarkers.map(m => m.label).join(',');
            const live = __washi.setup(options);
            const query = document.querySelectorAll;
            let scans = 0;
            document.querySelectorAll = function (selector) {
                if (selector === '*') { scans++; }
                return query.call(this, selector);
            };
            const census = __washi.setup({...options, \(Self.skipKey): true});
            const censusScans = scans;
            document.querySelectorAll = query;
            const liveAgain = __washi.setup(options);
            const repaginated = __washi.repaginate(options);
            return { liveLabels: labels(live), livePageCount: String(live.pageCount),
                     censusLabels: labels(census), censusPageCount: String(census.pageCount),
                     censusScans: String(censusScans),
                     liveAgainLabels: labels(liveAgain), repaginatedLabels: labels(repaginated),
                     repaginatedPageCount: String(repaginated.pageCount) };
            """)
        XCTAssertEqual(result["liveLabels"], "1,2,3", "ライブ表示は境界を収集する")
        XCTAssertNotEqual(result["livePageCount"], "1")
        XCTAssertEqual(result["censusLabels"], "", "census は境界を走査しない")
        XCTAssertEqual(result["censusScans"], "0", "skip 付き setup は DOM 全走査を行わない")
        XCTAssertEqual(result["censusPageCount"], result["livePageCount"],
                       "境界の走査を省いても pageCount は変わらない")
        XCTAssertEqual(result["liveAgainLabels"], "1,2,3", "鍵の無い setup は skip を引き継がない")
        XCTAssertEqual(result["repaginatedLabels"], "1,2,3", "ライブ表示の repaginate も収集する")
        XCTAssertEqual(result["repaginatedPageCount"], result["livePageCount"])
    }
}
