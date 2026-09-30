import AppKit
import WebKit
import XCTest
@testable import Washi

/// cooViewer-oxr.23/24/25/26/46/48/81: ReaderScripts のライフサイクル回帰(スクロールの
/// 補正・キー配送・ページ割りの制約・段組軸の検出)。クリックとタップの通知は
/// ReaderScriptClickDispatchTests、生成 style の出自判定は ReaderScriptStyleOwnershipTests、
/// メッセージの端から端までの回帰は ReaderScriptMessageEndToEndTests を参照。
@MainActor
final class ReaderScriptsRenderingLifecycleTests: XCTestCase {
    /// cooViewer-oxr.46 C10: 支援技術やフォーカス移動が起こした大きな
    /// スクロールを巻き戻さず、着地したページへ揃えて通知する。
    /// 半ページ未満のずれ(選択ドラッグ等)は従来どおり元のページへ戻す。
    func testScrollGuardFollowsLargeScrollAndReportsLandedPage() async throws {
        let body = (0..<400).map { "<p>本文の段落 \($0) です。ここは検証用の文章。</p>" }
            .joined()
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        try await harness.settleMessages()
        harness.messages.reset()

        // 支援技術やフォーカス移動を模して、文書のかなり先へスクロールさせる
        let _: Bool = try await harness.evaluate("""
            const el = document.scrollingElement || document.documentElement;
            window.scrollTo(Math.round(el.scrollWidth * 0.4),
                            Math.round(el.scrollHeight * 0.4));
            await new Promise(r => setTimeout(r, 500));
            return true;
            """)
        let reported = harness.messages
            .compactMap { $0["type"] as? String == "pageChanged" ? $0["page"] as? Int : nil }
        XCTAssertFalse(reported.isEmpty, "着地ページが通知されていない(巻き戻された)")
        let landedPage = try XCTUnwrap(reported.last)
        XCTAssertGreaterThan(landedPage, 0, "先頭ページへ巻き戻っている")

        // わずかなずれ(2px 超・半ページ未満)は元のページへ戻し、ページは動かさない
        harness.messages.reset()
        let _: Bool = try await harness.evaluate("""
            window.scrollBy(20, 20);
            await new Promise(r => setTimeout(r, 500));
            return true;
            """)
        let after = harness.messages
            .compactMap { $0["type"] as? String == "pageChanged" ? $0["page"] as? Int : nil }
        for page in after {
            XCTAssertEqual(page, landedPage, "わずかなずれでページが動いた")
        }
    }

    func testVisibleMediaOverlayHighlightDoesNotPostPageChanged() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(
            bodyHTML: "<p id=\"visible\">現在ページの読み上げ範囲</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let page: Int = try await harness.evaluate(
            "return __washi.mediaOverlayHighlight('visible', 'washi-speaking');")
        XCTAssertEqual(page, 0)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "pageChanged"), 0)
    }

    func testSetKeysEnabledChangesLiveKeyDispatch() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p>キー入力</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle(keysEnabled: true)
        harness.messages.reset()

        let disabled: Bool = try await harness.evaluate("""
            const value = __washi.setKeysEnabled(false);
            document.dispatchEvent(new KeyboardEvent('keydown', {
                key:'x', code:'KeyX', bubbles:true, cancelable:true
            }));
            return value;
            """)
        XCTAssertFalse(disabled)
        let receivedKey = try await harness.waitForMessage(type: "key")
        XCTAssertTrue(receivedKey)
        XCTAssertEqual(harness.messages.count(type: "key"), 1)

        harness.messages.reset()
        let enabled: Bool = try await harness.evaluate("""
            const value = __washi.setKeysEnabled(true);
            document.dispatchEvent(new KeyboardEvent('keydown', {
                key:'x', code:'KeyX', bubbles:true, cancelable:true
            }));
            return value;
            """)
        XCTAssertTrue(enabled)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "key"), 0)
    }

    /// cooViewer-oxr.81: FXL の組み込みキーも項目境界のめくりとして通知する。
    func testFixedLayoutBuiltInKeysPostBoundaryTurns() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p>固定レイアウト</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle(keysEnabled: true, fixedLayout: true)
        harness.messages.reset()

        let prevented: String = try await harness.evaluate("""
            const inputs = [
                {key:'ArrowLeft'}, {key:'ArrowRight'},
                {key:'ArrowUp'}, {key:'ArrowDown'},
                {key:'PageUp'}, {key:'PageDown'},
                {key:' '}, {key:' ', shiftKey:true},
                {key:'Home'}, {key:'End'}
            ];
            return inputs.map(input => {
                const event = new KeyboardEvent('keydown', {
                    key:input.key, bubbles:true, cancelable:true,
                    shiftKey:!!input.shiftKey
                });
                document.dispatchEvent(event);
                return event.defaultPrevented;
            }).join('|');
            """)
        XCTAssertEqual(prevented,
                       "true|true|true|true|true|true|true|true|true|true")
        try await harness.settleMessages()
        let directions = harness.messages.messages.compactMap { message -> Bool? in
            guard message["type"] as? String == "boundary" else { return nil }
            return message["forward"] as? Bool
        }
        XCTAssertEqual(directions,
                       [false, true, false, true, false, true,
                        true, false, false, true])
    }

    func testPaginationNeutralizesHTMLMinMaxConstraints() async throws {
        let body = """
            <style>
              html { writing-mode:vertical-rl; max-width:20em; max-height:20em;
                     min-width:20em; min-height:20em; }
              p { margin:0; }
              p + p { break-before:column; -webkit-column-break-before:always; }
            </style>
            <p id="first">第一段</p><p id="second">第二段</p><p>第三段</p>
            """
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle(spread: true)

        let constraints: String = try await harness.evaluate("""
            const style = getComputedStyle(document.documentElement);
            return [style.maxWidth, style.maxHeight,
                    style.minWidth, style.minHeight].join('|');
            """)
        XCTAssertEqual(constraints, "none|none|0px|0px")

        let pitch: Double = try await harness.evaluate("""
            const first = document.getElementById('first').getClientRects()[0];
            const second = document.getElementById('second').getClientRects()[0];
            return Math.abs(first.left - second.left);
            """)
        XCTAssertEqual(pitch, 344, accuracy: 2,
                       "カラム間隔は pageW(296) + gutter(48)")
    }

    func testColumnAxisDetectionAndForcedFallback() async throws {
        let body = "<style>html{writing-mode:vertical-rl}</style>"
            + (1...80).map { "<p>縦書きの本文 \($0)</p>" }.joined()
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()

        let supported: String = try await harness.evaluate("""
            const result = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return `${result.mode}|${result.pagesPerScreen}|${result.supportsColumnAxis}`;
            """)
        XCTAssertEqual(supported, "vrl|2|true")

        let fallback: String = try await harness.evaluate("""
            __washi.__forceNoColumnAxis = true;
            const result = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return `${result.mode}|${result.pagesPerScreen}|${result.supportsColumnAxis}`;
            """)
        XCTAssertEqual(fallback, "vrl|1|false")
    }
}
