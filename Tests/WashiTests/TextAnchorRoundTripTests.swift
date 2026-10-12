import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// 実際に本を開いて、画面先頭の位置が取れて同じ位置へ戻せることまで見る。
@MainActor
final class TextAnchorRoundTripTests: XCTestCase {
    func testAnchorIsCapturedAndRestoresToTheSamePlace() async throws {
        let body = (0..<300)
            .map { "<p>本文の段落 \($0) です。ここは読書位置の検証用の文章。</p>" }
            .joined()
        let publication = try EPUBFixtures.singleSpine(bodyHTML: body, name: "washi-anchor")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let window = makeOffscreenWindow(containing: view, ignoresMouseEvents: false)
        window.makeKeyAndOrderFront(nil)
        defer { closeReader(view, in: window, teardown: .unload, clearsDelegate: true) }

        // 待ちは固定時間でなく条件のポーリング(遅い CI でも落ちず、速い機では待たない)
        view.load(publication: publication)
        let paginated = await waitUntil(timeout: .seconds(15)) { view.pageCountInItem > 1 }
        XCTAssertTrue(paginated, "ページ割りが済んでいない")

        // 途中まで進めてからアンカー付きの位置を取る(進行率の移動はページが進むまで待つ)
        view.go(to: publication.locator(forSpineIndex: 0, progression: 0.5))
        let advanced = await waitUntil(timeout: .seconds(15)) { view.pageInItem > 0 }
        XCTAssertTrue(advanced, "進行率 0.5 へ移動していない")
        let saved = await view.currentLocatorWithTextAnchor()
        let anchor = try XCTUnwrap(saved.textOffset, "アンカーを取得できていない")
        XCTAssertGreaterThan(anchor, 0)
        let savedPage = view.pageInItem

        // 先頭へ戻してから、保存した位置へ復元する
        view.go(to: publication.locator(forSpineIndex: 0, progression: 0))
        let returned = await waitUntil(timeout: .seconds(15)) { view.pageInItem == 0 }
        XCTAssertTrue(returned, "先頭へ戻っていない: pageInItem=\(view.pageInItem)")

        // 着地は textRangeTask が終えた後、位置の再報告で pageInItem に写る
        view.go(to: saved)
        await view.textRangeTask?.value
        let restored = await waitUntil(timeout: .seconds(15)) { view.pageInItem == savedPage }
        XCTAssertTrue(restored, "アンカーで同じページへ戻れていない: "
                      + "pageInItem=\(view.pageInItem) 期待 \(savedPage)")
    }
}
