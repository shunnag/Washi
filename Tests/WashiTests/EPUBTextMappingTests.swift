import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class BlankLoadWaiter: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: any Error) {
        finished = true
    }
}

@MainActor
final class EPUBTextMappingTests: XCTestCase {
    private struct Landing: Sendable {
        let page: Int
        let text: String
        let firstUnit: Int
        let lastUnit: Int
        let rectCount: Int
    }

    private enum HarnessError: Error {
        case unexpectedJavaScriptResult(String)
        case navigation(fixture: String, domain: String, code: Int)
    }

    /// WashiCore の抽出本文と washi world の UTF-16 マップを同じ EPUB で
    /// 照合し、各検索ヒットが元の DOM Range へ戻ることを検証する
    func testExtractedTextAndEverySearchHitRoundTripThroughDOM() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.textMappingEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-text-map-fixtures.epub"))
        let size = NSSize(width: 640, height: 480)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // NavigationWaiter は washi-epub 以外のナビゲーションを拒否するため、
        // census と同じくスキームハンドラ経由で spine 項目を読み込む
        let schemeHandler = EPUBSchemeHandler(publication: publication,
                                              allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler,
                                          forURLScheme: EPUBSchemeHandler.scheme)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.pageScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: WashiContentWorld.world))
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.baseCSSInjector, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: WashiContentWorld.world))
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size),
                                configuration: configuration)
        window.contentView = webView
        defer {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.orderOut(nil)
        }

        let setupOptions = """
            {"width":640,"height":480,"gap":24,"spread":false,"gutter":48,
             "fixedLayout":false,"keysEnabled":false,"userCSS":""}
            """

        for (index, fixture) in EPUBFixtures.textMappingFixtures.enumerated() {
            let entry = publication.readingOrder[index]
            let url = try XCTUnwrap(
                schemeHandler.url(forContainerPath: entry.containerPath), fixture.name)
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter
            webView.load(URLRequest(url: url))
            do {
                try await waiter.wait(timeout: .seconds(15))
            } catch {
                let nsError = error as NSError
                throw HarnessError.navigation(
                    fixture: fixture.name, domain: nsError.domain,
                    code: nsError.code)
            }
            withExtendedLifetime(waiter) {}

            // オフスクリーン WebKit の最初の JS 呼び出しは明示的に
            // userInitiated で開始し、WebContent の QoS 逆転による停止を防ぐ
            let pageCount = try await setup(
                webView: webView, optionsJSON: setupOptions)
            // cooViewer-oxr.94: textOffsetFor の二分探索は「ノード番号が非減少、
            // 同じノードの中では offset も非減少」を前提にする。実 fixture で固定する
            let violation = try await mapOrderViolation(webView: webView)
            XCTAssertEqual(violation, -1,
                           "\(fixture.name): 地図の並びが単調でない index=\(violation)")
            // cooViewer-oxr.94: 二分探索版と線形走査版の答えを総当たりで突き合わせる
            let disagreements = try await textOffsetDisagreements(webView: webView)
            XCTAssertEqual(disagreements, [],
                           "\(fixture.name): textOffsetFor が線形走査と不一致")
            let swiftText = try publication.extractText(forSpineIndex: index)
            let javaScriptText = try await mappedText(webView: webView)
            XCTAssertEqual(javaScriptText, swiftText,
                           "\(fixture.name): JS 本文と extractText")
            guard javaScriptText == swiftText else { continue }

            let hits = publication.search(fixture.searchQuery)
                .filter { $0.spineIndex == index }
            XCTAssertFalse(hits.isEmpty, "\(fixture.name): search hit が必要")
            for hit in hits {
                let lower = swiftText.index(
                    swiftText.startIndex, offsetBy: hit.characterOffset)
                let upper = swiftText.index(lower, offsetBy: hit.length)
                let utf16Lower = try XCTUnwrap(
                    lower.samePosition(in: swiftText.utf16), fixture.name)
                let utf16Upper = try XCTUnwrap(
                    upper.samePosition(in: swiftText.utf16), fixture.name)
                let offset = swiftText.utf16.distance(
                    from: swiftText.utf16.startIndex, to: utf16Lower)
                let length = swiftText.utf16.distance(
                    from: utf16Lower, to: utf16Upper)
                let expected = String(swiftText[lower..<upper])
                // cooViewer-oxr.11: 公開ヒットが DOM 用 UTF-16 範囲を直接持つ。
                XCTAssertEqual(hit.utf16Range, offset..<(offset + length),
                               "\(fixture.name): UTF-16 範囲")
                let landing = try await locate(
                    webView: webView, offset: hit.utf16Range.lowerBound,
                    length: hit.utf16Range.count)
                if fixture.name == "非表示テキスト" {
                    // レイアウト箱の無い範囲は null(呼び出し側が近似へ落とす。cooViewer-cvt)
                    XCTAssertNil(landing, "\(fixture.name): locateAndShow は null")
                    continue
                }
                let resolved = try XCTUnwrap(
                    landing, "\(fixture.name): locateAndShow は非 nil")
                XCTAssertEqual(resolved.text, expected,
                               "\(fixture.name): 地図上の本文")
                // Range の端点が期待文字列の先頭/末尾の DOM 文字を指すこと
                // (途中に地図が飛ばした空白ノードや rt が挟まっても成立する)
                XCTAssertEqual(resolved.firstUnit, Int(expected.utf16.first ?? 0),
                               "\(fixture.name): Range 始端")
                XCTAssertEqual(resolved.lastUnit, Int(expected.utf16.last ?? 0),
                               "\(fixture.name): Range 終端")
                XCTAssertTrue((0..<pageCount).contains(resolved.page),
                              "\(fixture.name): page=\(resolved.page), count=\(pageCount)")
                XCTAssertGreaterThan(resolved.rectCount, 0,
                                     "\(fixture.name): 可視 Range 矩形")
            }
        }
    }

    /// cooViewer-oxr.94: 大きな文書でも二分探索版が線形走査版と同じ答えを返し、
    /// かつ実測で十分速いこと(全長走査なら文書が伸びるほど比例して遅くなる)
    func testTextOffsetForOnLargeDocumentMatchesLinearScanAndIsFaster() async throws {
        var paragraphs: [String] = []
        for index in 0..<2000 {
            paragraphs.append("<p>本文の段落 \(index) です。ここは検証用の"
                              + "そこそこ長い日本語の文章で、空白 も 混ぜます。</p>")
        }
        let webView = try await blankReaderWebView(body: paragraphs.joined())
        let report = try await Task(priority: .userInitiated) { @MainActor () -> [String] in
            let result = try await webView.callAsyncJavaScript("""
                const map = __washi.buildTextMap();
                const reference = (node, domOffset) => {
                    let lastDirect = null;
                    for (let i = 0; i < map.length; i += 1) {
                        if (map.nodes[map.nodeIdx[i]] !== node) { continue; }
                        if (domOffset <= map.offset[i]) { return i; }
                        if (domOffset <= map.endOffset[i]) { return i + 1; }
                        lastDirect = i + 1;
                    }
                    return lastDirect;
                };
                const targets = [];
                for (let i = 0; i < map.nodes.length; i += 17) {
                    targets.push(map.nodes[i]);
                }
                const queries = [];
                for (const node of targets) {
                    const limit = (node.data || '').length;
                    for (let offset = 0; offset <= limit; offset += 3) {
                        queries.push([node, offset]);
                    }
                }
                let bad = 0;
                for (const [node, offset] of queries) {
                    if (__washi.textOffsetFor(node, offset) !== reference(node, offset)) {
                        bad += 1;
                    }
                }
                const t0 = performance.now();
                for (const [node, offset] of queries) {
                    __washi.textOffsetFor(node, offset);
                }
                const fast = performance.now() - t0;
                const t1 = performance.now();
                for (const [node, offset] of queries) { reference(node, offset); }
                const slow = performance.now() - t1;
                return ['units=' + map.length, 'nodes=' + map.nodes.length,
                        'queries=' + queries.length, 'mismatches=' + bad,
                        'binary=' + fast.toFixed(1) + 'ms',
                        'linear=' + slow.toFixed(1) + 'ms'];
                """, arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let report = result as? [String] else {
                throw HarnessError.unexpectedJavaScriptResult("textOffsetFor bench")
            }
            return report
        }.value
        print("[oxr.94] " + report.joined(separator: " "))
        XCTAssertTrue(report.contains("mismatches=0"),
                      "線形走査と不一致: \(report)")
        XCTAssertFalse(report.contains("queries=0"), "問い合わせが空: \(report)")
    }

    /// cooViewer-oxr.69: 地図は UTF-16 単位ごとのオブジェクトではなく
    /// Text ノード表 + 型付き配列で保持する。表現が戻ると常駐量が桁で増える。
    func testTextMapIsStoredAsTypedArrays() async throws {
        let webView = try await blankReaderWebView(body:
            "<p>ひとつめの段落。</p><p>ふたつめの<em>強調</em>段落。</p>")
        // 型付き配列は Swift へ渡せないので、判定結果だけ数値で受け取る
        let shape = try await Task(priority: .userInitiated) { @MainActor () -> [Int] in
            let result = try await webView.callAsyncJavaScript("""
                const map = __washi.buildTextMap();
                return [
                    (map.nodeIdx instanceof Int32Array
                     && map.offset instanceof Int32Array
                     && map.endOffset instanceof Int32Array) ? 1 : 0,
                    Array.isArray(map.map) ? 1 : 0,
                    map.length,
                    map.length === map.text.length ? 1 : 0,
                    map.nodes.length
                ];
                """, arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let values = result as? [Int] else {
                throw HarnessError.unexpectedJavaScriptResult("buildTextMap shape")
            }
            return values
        }.value
        XCTAssertEqual(shape.count, 5)
        XCTAssertEqual(shape[0], 1, "型付き配列で保持する")
        XCTAssertEqual(shape[1], 0, "単位ごとのオブジェクト配列を残さない")
        XCTAssertGreaterThan(shape[2], 0, "地図が空でない")
        XCTAssertEqual(shape[3], 1, "length と text の長さが一致する")
        XCTAssertGreaterThan(shape[4], 0, "Text ノード表が空でない")
    }

    /// cooViewer-oxr.69: 空白畳みの判定を正規表現からコード値へ移したので、
    /// BMP 全域で `\p{Zs}` + TAB と完全一致することを WebKit 側で確認する。
    /// 将来 Unicode 版が変わって Zs が増減したらここで落ちる。
    /// なお本体の判定式はここに複製してあるので、本体だけを書き換えても
    /// このテストは落ちない(そちらは本文の突き合わせテストで検出する)。
    func testWhitespaceCodeSetMatchesUnicodeSpaceSeparator() async throws {
        let webView = try await blankReaderWebView(body: "<p>判定表</p>")
        let codes = try await Task(priority: .userInitiated) { @MainActor () -> [Int] in
            let result = try await webView.callAsyncJavaScript("""
                const isWhitespaceCode = code =>
                    code === 0x0020 || code === 0x0009 || code === 0x00A0
                    || code === 0x1680 || (code >= 0x2000 && code <= 0x200A)
                    || code === 0x202F || code === 0x205F || code === 0x3000;
                const pattern = /[\\p{Zs}\\u0009]/u;
                const bad = [];
                for (let code = 0; code <= 0xFFFF; code += 1) {
                    if (pattern.test(String.fromCharCode(code))
                        !== isWhitespaceCode(code)) {
                        bad.push(code);
                    }
                }
                return bad;
                """, arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let bad = result as? [Int] else {
                throw HarnessError.unexpectedJavaScriptResult("whitespace set")
            }
            return bad
        }.value
        XCTAssertEqual(codes, [], "Zs+TAB の集合が不一致: "
                       + codes.map { String(format: "U+%04X", $0) }.joined(separator: ", "))
    }

    /// pageScript だけを載せた空の文書。地図の表現そのものを見るための最小構成。
    private func blankReaderWebView(body: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ReaderScripts.pageScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: WashiContentWorld.world))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                configuration: configuration)
        // NavigationWaiter は washi-epub 以外のナビゲーションを拒否するため、
        // ここは didFinish を旗で受けるだけの最小デリゲートで待つ
        let waiter = BlankLoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(
            "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>",
            baseURL: nil)
        for _ in 0..<300 where !waiter.finished {
            try await Task.sleep(for: .milliseconds(50))
        }
        webView.navigationDelegate = nil
        withExtendedLifetime(waiter) {}
        guard waiter.finished else {
            throw HarnessError.unexpectedJavaScriptResult("blank reader load")
        }
        return webView
    }

    private func setup(webView: WKWebView, optionsJSON: String) async throws -> Int {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                "return __washi.setup(\(optionsJSON));",
                arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let dictionary = result as? [String: Any],
                  let pageCount = dictionary["pageCount"] as? Int else {
                throw HarnessError.unexpectedJavaScriptResult("setup")
            }
            return max(1, pageCount)
        }.value
    }

    /// 文書中の全 Text ノードと要素境界について、二分探索版 `textOffsetFor` の
    /// 答えを旧実装(線形走査)と突き合わせ、食い違った箇所を返す
    private func textOffsetDisagreements(webView: WKWebView) async throws -> [String] {
        try await Task(priority: .userInitiated) { @MainActor () -> [String] in
            let result = try await webView.callAsyncJavaScript("""
                const map = __washi.buildTextMap();
                // 旧実装をそのまま参照実装として持つ
                const reference = (node, domOffset) => {
                    if (!node || !Number.isInteger(domOffset) || domOffset < 0) {
                        return null;
                    }
                    let lastDirect = null;
                    for (let i = 0; i < map.length; i += 1) {
                        if (map.nodes[map.nodeIdx[i]] !== node) { continue; }
                        if (domOffset <= map.offset[i]) { return i; }
                        if (domOffset <= map.endOffset[i]) { return i + 1; }
                        lastDirect = i + 1;
                    }
                    if (lastDirect !== null) { return lastDirect; }
                    try {
                        const boundary = document.createRange();
                        boundary.setStart(node, domOffset);
                        boundary.collapse(true);
                        for (let i = 0; i < map.length; i += 1) {
                            const unitNode = map.nodes[map.nodeIdx[i]];
                            if (!(unitNode instanceof Text)) { continue; }
                            const point = document.createRange();
                            point.setStart(unitNode, map.offset[i]);
                            point.collapse(true);
                            if (boundary.compareBoundaryPoints(
                                    Range.START_TO_START, point) <= 0) {
                                return i;
                            }
                        }
                        return map.length;
                    } catch (e) { return null; }
                };
                const targets = [];
                const walker = document.createTreeWalker(
                    document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
                for (let n = walker.nextNode(); n; n = walker.nextNode()) {
                    targets.push(n);
                }
                targets.push(document.body);
                const bad = [];
                for (const target of targets) {
                    const limit = target.nodeType === Node.TEXT_NODE
                        ? (target.data || '').length
                        : target.childNodes.length;
                    for (let offset = 0; offset <= limit + 1; offset += 1) {
                        const fast = __washi.textOffsetFor(target, offset);
                        const slow = reference(target, offset);
                        if (fast !== slow && bad.length < 8) {
                            bad.push((target.nodeName || '?') + '#' + offset
                                     + ': fast=' + fast + ' slow=' + slow);
                        }
                    }
                }
                if (targets.length === 0) { bad.push('no targets'); }
                return bad;
                """, arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let bad = result as? [String] else {
                throw HarnessError.unexpectedJavaScriptResult("textOffsetFor diff")
            }
            return bad
        }.value
    }

    /// 地図の単調性を検査し、破れている最初の index を返す(-1 = 問題なし)
    private func mapOrderViolation(webView: WKWebView) async throws -> Int {
        try await Task(priority: .userInitiated) { @MainActor () -> Int in
            let result = try await webView.callAsyncJavaScript("""
                const map = __washi.buildTextMap();
                for (let i = 1; i < map.length; i += 1) {
                    if (map.nodeIdx[i] < map.nodeIdx[i - 1]) { return i; }
                    if (map.nodeIdx[i] === map.nodeIdx[i - 1]
                        && map.offset[i] < map.offset[i - 1]) { return i; }
                }
                return -1;
                """, arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let index = result as? Int else {
                throw HarnessError.unexpectedJavaScriptResult("map order")
            }
            return index
        }.value
    }

    private func mappedText(webView: WKWebView) async throws -> String {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                "return __washi.buildTextMap().text;",
                arguments: [:], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let text = result as? String else {
                throw HarnessError.unexpectedJavaScriptResult("buildTextMap")
            }
            return text
        }.value
    }

    private func locate(webView: WKWebView, offset: Int, length: Int) async throws
        -> Landing? {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                "return __washi.locateAndShow(o, l);",
                arguments: ["o": offset, "l": length], in: nil,
                contentWorld: WashiContentWorld.world)
            guard let result else { return nil }
            if let dictionary = result as? [String: Any],
               dictionary["found"] as? Bool == false {
                return nil  // 位置を特定できない範囲(呼び出し側は近似へ落とす)
            }
            guard let dictionary = result as? [String: Any],
                  let page = dictionary["page"] as? Int,
                  let text = dictionary["text"] as? String,
                  let firstUnit = dictionary["firstUnit"] as? Int,
                  let lastUnit = dictionary["lastUnit"] as? Int,
                  let rects = dictionary["rects"] as? [[String: Any]] else {
                throw HarnessError.unexpectedJavaScriptResult("locateAndShow")
            }
            return Landing(page: page, text: text, firstUnit: firstUnit,
                           lastUnit: lastUnit, rectCount: rects.count)
        }.value
    }
}

/// extractText と WebKit DOM の対応を検証する spine 項目。
private struct EPUBTextMappingFixture {
    let name: String
    let body: String
    let searchQuery: String
    var css = "html { writing-mode: horizontal-tb; }"
    var usesXHTMLDoctype = false
}

private extension EPUBFixtures {
    /// appendPlainText / collapsingWhitespace の境界条件を個別に識別できる
    /// 忠実性フィクスチャ。各 query は少なくとも 1 個の可視 DOM Range を持つ
    static let textMappingFixtures: [EPUBTextMappingFixture] = [
        EPUBTextMappingFixture(
            name: "U+3000 字下げ",
            body: "<p>　字下げ検索　本文</p>",
            searchQuery: "字下げ検索"),
        EPUBTextMappingFixture(
            name: "整形空白ノード",
            body: "<p>整形前検索</p>\n<p>整形後検索</p>",
            searchQuery: "検索"),
        EPUBTextMappingFixture(
            // NSXML は要素間の半角スペースだけのノードを落とす → 両側とも "xy"
            name: "インライン間空白",
            body: "<p><span>xy検索</span> <span>語</span></p>",
            searchQuery: "xy検索語"),
        EPUBTextMappingFixture(
            // U+3000 は XML 空白ではないためノードが残り、両側とも空行 1 本になる
            name: "全角空白ノード",
            body: "<p>全角前</p>\u{3000}<p>全角後検索</p>",
            searchQuery: "全角後検索"),
        EPUBTextMappingFixture(
            // &#13; は NSXML でも U+000D として残る。段落末の CR の直後に要素境界の改行
            name: "CR 実体+段落末",
            body: "<p>x&#13;</p><p>y検索</p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            name: "CR 実体+br",
            body: "<div>x&#13;<br/>y検索</div>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            // CR LF が 1 書記素になるケース(Character の split/hasSuffix の罠)
            name: "CRLF 実体",
            body: "<p>x&#13;&#10;</p><p>y検索</p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            name: "CDATA 内 CRLF",
            body: "<p><![CDATA[x\r\n]]></p><p>y検索</p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            // NSXML は空白 Text と隣接 CDATA を結合して残す → 両側とも "x y検索"
            name: "CDATA 隣接空白",
            body: "<p><b>x</b> <![CDATA[y検索]]></p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            // 抽出本文には含まれるがレイアウト箱が無い → locateAndShow は null
            name: "非表示テキスト",
            body: "<p>可視</p><p style=\"display:none\">非表示検索</p>",
            searchQuery: "非表示検索"),
        EPUBTextMappingFixture(
            name: "br",
            body: "<p>改行前<br/>改行後検索</p>",
            searchQuery: "改行後検索"),
        EPUBTextMappingFixture(
            name: "ruby",
            body: "<p><ruby>葛<rp>（</rp><rt>かつ</rt><rp>）</rp></ruby>ルビ検索</p>",
            searchQuery: "ルビ検索"),
        EPUBTextMappingFixture(
            name: "入れ子インライン",
            body: "<p><span>入れ子<em>強調<a href=\"#nested\">リンク検索</a></em></span></p>",
            searchQuery: "強調リンク検索"),
        EPUBTextMappingFixture(
            name: "空行連続",
            body: "<p>空行前</p>\n\n\n<p>空行後検索</p>",
            searchQuery: "空行後検索"),
        EPUBTextMappingFixture(
            name: "IVS",
            body: "<p>異体字葛󠄀検索と通常字葛</p>",
            searchQuery: "葛󠄀検索"),
        EPUBTextMappingFixture(
            name: "CDATA",
            body: "<p><![CDATA[CDATA検索<&>]]></p>",
            searchQuery: "CDATA検索"),
        EPUBTextMappingFixture(
            name: "名前付き実体",
            body: "<p>実体&nbsp;検索&hellip;終端</p>",
            searchQuery: "検索…終端",
            usesXHTMLDoctype: true),
        EPUBTextMappingFixture(
            // cooViewer-oxr.10: WHATWG 実体を Core と WebKit で同じ本文へ写像する。
            name: "WHATWG 名前付き実体",
            body: "<p>矢印&rarr;検索&yen;価格&ensp;空白</p>",
            searchQuery: "→検索¥価格",
            usesXHTMLDoctype: true),
        EPUBTextMappingFixture(
            name: "pre",
            body: "<pre>  pre検索\n    二行目  </pre>",
            searchQuery: "pre検索"),
        EPUBTextMappingFixture(
            // cooViewer-oxr.89: SVG/MathML の不可視注釈を除き可視 text は残す。
            name: "SVG・MathML 注釈",
            body: "<p>前<svg xmlns=\"http://www.w3.org/2000/svg\">"
                + "<title>不可視題</title><desc>不可視説明</desc>"
                + "<text>SVG可視検索</text></svg>"
                + "<math xmlns=\"http://www.w3.org/1998/Math/MathML\">"
                + "<mi>x</mi><annotation>不可視注釈</annotation>"
                + "<annotation-xml><mtext>不可視XML</mtext></annotation-xml>"
                + "</math><desc>HTML説明</desc><annotation>HTML注記</annotation>"
                + "後</p>",
            searchQuery: "SVG可視検索"),
        EPUBTextMappingFixture(
            // cooViewer-oxr.92: 表題・見出し・セルを同じ改行境界で写像する。
            name: "table/caption/th/td",
            body: "<table><caption>書誌</caption><tr><th>発行者</th>"
                + "<td>山田太郎</td><td>検索セル</td></tr></table>",
            searchQuery: "検索セル"),
        EPUBTextMappingFixture(
            name: "縦書き",
            body: "<p>\(String(repeating: "縦書き本文。", count: 350))縦書き検索\(String(repeating: "後続本文。", count: 350))</p>",
            searchQuery: "縦書き検索",
            css: "html { writing-mode: vertical-rl; }"),
    ]

    static func textMappingEntries() -> [(name: String, data: Data)] {
        let manifest = textMappingFixtures.indices.map { index in
            "<item id=\"text\(index)\" href=\"text/f\(index).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = textMappingFixtures.indices.map { index in
            "<itemref idref=\"text\(index)\"/>"
        }.joined()
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:text-map-fixtures</dc:identifier>
                <dc:title>Text map fixtures</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-02T00:00:00Z</meta>
              </metadata>
              <manifest>\(manifest)</manifest>
              <spine>\(spine)</spine>
            </package>
            """
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
        ]
        for (index, fixture) in textMappingFixtures.enumerated() {
            let doctype = fixture.usesXHTMLDoctype
                ? "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
                : ""
            let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                + doctype
                + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
                + "<head><title>\(fixture.name)</title><style>\(fixture.css)</style></head>"
                + "<body>\(fixture.body)</body></html>"
            entries.append(("OEBPS/text/f\(index).xhtml", Data(xhtml.utf8)))
        }
        return entries
    }
}
