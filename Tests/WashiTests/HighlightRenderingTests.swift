import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// 実際に本を開き、CSS Custom Highlight API へ登録されるところまで見る。
@MainActor
final class HighlightRenderingTests: XCTestCase {
    func testHighlightsAreRegisteredForTheVisibleItem() async throws {
        let body = (0..<60).map { "<p>本文の段落 \($0) です。検証用の文章。</p>" }
            .joined()
        let publication = try EPUBFixtures.singleSpine(bodyHTML: body, name: "washi-highlight")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let window = makeOffscreenWindow(containing: view, ignoresMouseEvents: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }

        view.load(publication: publication)
        for _ in 0..<300 where view.pageCountInItem <= 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(view.pageCountInItem, 1)

        view.highlights = [
            EPUBHighlight(id: "a", spineIndex: 0, utf16Offset: 5, utf16Length: 8,
                          style: .yellow),
            EPUBHighlight(id: "b", spineIndex: 0, utf16Offset: 40, utf16Length: 6,
                          style: .green, note: "メモ"),
            // 別の項目のものは描かない
            EPUBHighlight(id: "c", spineIndex: 5, utf16Offset: 0, utf16Length: 3),
        ]
        try await Task.sleep(for: .milliseconds(400))

        let registered = try await view.evaluateForTest(
            "return CSS.highlights ? Array.from(CSS.highlights.keys()).sort() : [];")
        let keys = try XCTUnwrap(registered as? [String])
        XCTAssertEqual(keys, ["washi-hl-green", "washi-hl-yellow"],
                       "登録された見た目が期待と違う: \(keys)")

        // 空にすると解除される
        view.highlights = []
        try await Task.sleep(for: .milliseconds(300))
        let cleared = try await view.evaluateForTest(
            "return CSS.highlights ? CSS.highlights.size : -1;")
        XCTAssertEqual(cleared as? Int, 0, "解除されていない")
    }
}
