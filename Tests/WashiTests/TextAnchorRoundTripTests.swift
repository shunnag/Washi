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
        defer { window.contentView = nil; window.orderOut(nil) }

        view.load(publication: publication)
        for _ in 0..<300 where view.pageCountInItem <= 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(view.pageCountInItem, 1, "ページ割りが済んでいない")

        // 途中まで進めてからアンカー付きの位置を取る
        view.go(to: publication.locator(forSpineIndex: 0, progression: 0.5))
        try await Task.sleep(for: .milliseconds(400))
        let saved = await view.currentLocatorWithTextAnchor()
        let anchor = try XCTUnwrap(saved.textOffset, "アンカーを取得できていない")
        XCTAssertGreaterThan(anchor, 0)
        let savedPage = view.pageInItem

        // 先頭へ戻してから、保存した位置へ復元する
        view.go(to: publication.locator(forSpineIndex: 0, progression: 0))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.pageInItem, 0)

        view.go(to: saved)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(view.pageInItem, savedPage, "アンカーで同じページへ戻れていない")
    }
}
