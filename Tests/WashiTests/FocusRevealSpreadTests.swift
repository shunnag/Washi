import AppKit
import WebKit
import XCTest
@testable import Washi

/// Washi-huz: WebKit の中央寄せ reveal が見開き先頭のリンクを画面外へ戻さない。
@MainActor
final class FocusRevealSpreadTests: XCTestCase {
    func testVerticalRLFocusRevealKeepsFirstPageLinksVisible() async throws {
        try await verifyFocusReveals(vertical: true)
    }

    func testHorizontalFocusRevealKeepsFirstPageLinksVisible() async throws {
        try await verifyFocusReveals(vertical: false)
    }

    private func snapshot(_ view: EPUBReaderView, _ body: String) async throws
        -> [String: Double] {
        let value = try await view.evaluateForTest(body)
        return try XCTUnwrap(value as? [String: Double])
    }

    private func verifyFocusReveals(vertical: Bool) async throws {
        // 1 段落を 1 列に固定し、偶数ページの冒頭を必ず見開きの先頭に置く。
        let mode = vertical ? "vertical-rl" : "horizontal-tb"
        let body = """
            <style>
              html { writing-mode:\(mode); }
              p { margin:0; }
              p + p { break-before:column; -webkit-column-break-before:always; }
            </style>
            """ + (0..<24).map {
                "<p><a id=\"link\($0)\" href=\"#link0\">リンク</a> 本文 \($0)</p>"
            }.joined()
        let publication = try EPUBFixtures.singleSpine(
            bodyHTML: body, name: "washi-focus-reveal-\(mode)")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 752, height: 508))
        var settings = view.settings
        settings.columnMode = .double
        settings.pageTurnStyle = .none
        view.settings = settings
        let spy = ReaderObservationSpy()
        view.delegate = spy
        let window = makeOffscreenWindow(containing: view)
        defer {
            closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true)
        }
        view.load(publication: publication)
        guard await waitUntil(timeout: .seconds(8), { spy.moveCount > 0 }) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let web = try view.firstWebView()
        let shown = await waitUntil(timeout: .seconds(8)) { web.alphaValue == 1 }
        XCTAssertTrue(shown, "本文の表示が戻らない")
        XCTAssertEqual(view.pagesPerScreen, 2)
        XCTAssertGreaterThanOrEqual(view.pageCountInItem, 24)

        // 実測したページ送りの符号と幅を使い、vrl の原点校正もそのまま検証する。
        let geometry = try await snapshot(view, """
            __washi.showPage(0);
            const origin = window.scrollX;
            __washi.showPage(2);
            const pitch = (window.scrollX - origin) / 2;
            __washi.showPage(0);
            return {origin:origin, pitch:pitch, pageWidth:innerWidth - Math.abs(pitch)};
            """)
        let origin = try XCTUnwrap(geometry["origin"])
        let pitch = try XCTUnwrap(geometry["pitch"])
        let pageWidth = try XCTUnwrap(geometry["pageWidth"])
        XCTAssertGreaterThan(abs(pitch), 0)
        XCTAssertGreaterThan(pageWidth, 0)

        for page in [6, 10, 14] {
            let placement = try await snapshot(view, """
                const page = __washi.showFragment('link\(page)');
                const r = document.getElementById('link\(page)').getBoundingClientRect();
                const center = (r.left + r.right) / 2;
                return {page:page, center:\(vertical ? "innerWidth - center" : "center")};
                """)
            XCTAssertEqual(placement["page"], Double(page), "リンクは見開き先頭のページ")
            let center = try XCTUnwrap(placement["center"])
            XCTAssertGreaterThan(center, 0)
            XCTAssertLessThan(center, pageWidth / 2, "中央寄せで丸めを誤るページ前半の要素")

            _ = try await view.evaluateForTest("""
                if (document.activeElement) { document.activeElement.blur(); }
                __washi.showPage(0);
                """)
            try await Task.sleep(for: .milliseconds(350))
            let revealed = try await snapshot(view, """
                document.getElementById('link\(page)').focus();
                const rawPage = Math.max(0, Math.round((window.scrollX - \(origin)) / \(pitch)));
                return {rawSpread:rawPage - rawPage % 2};
                """)
            XCTAssertEqual(revealed["rawSpread"], Double(page - 2),
                           "修正前の offset 丸めでは前の見開きに着地する条件")
            let reported = await waitUntil(timeout: .seconds(3)) { view.pageInItem == page }
            XCTAssertTrue(reported, "フォーカス要素の見開きが native に通知されない")
            // 補正スクロールが起こす次の guard も終わってから矩形を確認する。
            try await Task.sleep(for: .milliseconds(350))
            let visible = try await snapshot(view, """
                const el = document.getElementById('link\(page)');
                const r = el.getBoundingClientRect();
                return {left:r.left, right:r.right, top:r.top, bottom:r.bottom,
                        width:innerWidth, height:innerHeight,
                        focused:Number(document.activeElement === el)};
                """)
            XCTAssertEqual(visible["focused"], 1)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(visible["left"]), -1)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(visible["top"]), -1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(visible["right"]),
                                     try XCTUnwrap(visible["width"]) + 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(visible["bottom"]),
                                     try XCTUnwrap(visible["height"]) + 1)
            XCTAssertEqual(view.pageInItem, page)
            XCTAssertTrue((view.pageInItem..<(view.pageInItem + view.pagesPerScreen)).contains(page))
        }

        // focus を保持したまま別の見開きへスクロールしても、消費済み focus は使わない。
        let moved = try await snapshot(view, """
            window.scrollTo(\(origin) + 8.2 * \(pitch), 0);
            await new Promise(resolve => setTimeout(resolve, 500));
            return {focused:Number(document.activeElement.id === 'link14'), x:window.scrollX};
            """)
        XCTAssertEqual(moved["focused"], 1)
        XCTAssertEqual(try XCTUnwrap(moved["x"]), origin + 8 * pitch, accuracy: 2)
        XCTAssertEqual(view.pageInItem, 8, "通常のスクロールは offset から着地する")

        // reveal を伴わない focus は guard が来なくても失効し、後の自動スクロールを奪わない。
        let expired = try await snapshot(view, """
            document.getElementById('link18').focus({preventScroll:true});
            await new Promise(resolve => setTimeout(resolve, 600));
            window.scrollTo(\(origin) + 4.2 * \(pitch), 0);
            await new Promise(resolve => setTimeout(resolve, 500));
            return {focused:Number(document.activeElement.id === 'link18'), x:window.scrollX};
            """)
        XCTAssertEqual(expired["focused"], 1)
        XCTAssertEqual(try XCTUnwrap(expired["x"]), origin + 4 * pitch, accuracy: 2)
        XCTAssertEqual(view.pageInItem, 4, "古い focus を後のスクロールに流用しない")
    }
}
