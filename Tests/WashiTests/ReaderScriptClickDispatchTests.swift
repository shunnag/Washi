import AppKit
import WebKit
import XCTest
@testable import Washi

/// cooViewer-oxr.27/32/82: クリックとタップの通知(link・tap・noteref の付随情報・
/// 操作要素の除外・ダブルクリック待ちの opt-in)。
@MainActor
final class ReaderScriptClickDispatchTests: XCTestCase {
    func testSynthesizedAnchorClickPostsLinkButNeverTap() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(
            bodyHTML: "<a id=\"link\" href=\"#chapter\">章へ</a><p id=\"plain\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            document.body.dispatchEvent(new MouseEvent('mousedown', {
                bubbles:true, clientX:200, clientY:100, button:0
            }));
            document.body.dispatchEvent(new MouseEvent('mouseup', {
                bubbles:true, clientX:200, clientY:100, button:0
            }));
            document.getElementById('link').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:0, clientX:0, clientY:0, button:0
            }));
            document.getElementById('plain').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:0, clientX:0, clientY:0, button:0
            }));
            return true;
            """)
        let receivedLink = try await harness.waitForMessage(type: "link")
        XCTAssertTrue(receivedLink)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "link"), 1)
        XCTAssertEqual(harness.messages.first(type: "link")?["href"] as? String, "#chapter")
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    /// cooViewer-oxr.32: noteref の意味情報、戻りリンク、実測矩形を通知する。
    func testNoterefClickPostsMetadataBacklinkAndAnchorRect() async throws {
        let body = """
            <div xmlns:epub="http://www.idpf.org/2007/ops">
              <p><a id="ref1" epub:type="noteref" role="doc-noteref"
                    href="#n1" style="display:inline-block;width:88px;height:24px">注1</a></p>
              <aside id="n1" epub:type="footnote">
                <p>脚注本文 <a href="#ref1">戻る</a></p>
              </aside>
            </div>
            """
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let expectedJSON: String = try await harness.evaluate("""
            const anchor = document.getElementById('ref1');
            const rect = anchor.getBoundingClientRect();
            anchor.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:rect.x + 2, clientY:rect.y + 2, button:0
            }));
            return JSON.stringify([rect.x, rect.y, rect.width, rect.height]);
            """)
        let expectedData = try XCTUnwrap(expectedJSON.data(using: .utf8))
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: expectedData) as? [Double])
        XCTAssertEqual(expected.count, 4)
        let receivedLink = try await harness.waitForMessage(type: "link")
        XCTAssertTrue(receivedLink)
        let message = try XCTUnwrap(harness.messages.first(type: "link"))

        XCTAssertEqual(message["href"] as? String, "#n1")
        XCTAssertEqual(message["epubType"] as? String, "noteref")
        XCTAssertEqual(message["role"] as? String, "doc-noteref")
        XCTAssertEqual(message["anchorId"] as? String, "ref1")
        XCTAssertEqual(message["backlink"] as? Bool, true)
        XCTAssertEqual(message["targetTag"] as? String, "aside")
        XCTAssertEqual(message["targetEpubType"] as? String, "footnote")
        let rect = try XCTUnwrap(message["anchorRect"] as? [String: Any])
        func number(_ key: String) -> Double? {
            if let value = rect[key] as? NSNumber { return value.doubleValue }
            return rect[key] as? Double
        }
        XCTAssertEqual(try XCTUnwrap(number("x")), expected[0], accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(number("y")), expected[1], accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(number("w")), expected[2], accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(number("h")), expected[3], accuracy: 0.001)
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    func testClickThatClearsExistingSelectionDoesNotPostTap() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(
            bodyHTML: "<p id=\"text\">選択中の本文をクリックする</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            const target = document.getElementById('text');
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(target);
            selection.removeAllRanges();
            selection.addRange(range);
            target.dispatchEvent(new MouseEvent('mousedown', {
                bubbles:true, clientX:40, clientY:40, button:0
            }));
            selection.removeAllRanges();
            target.dispatchEvent(new MouseEvent('mouseup', {
                bubbles:true, clientX:40, clientY:40, button:0
            }));
            target.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    /// cooViewer-oxr.82: ネイティブ操作要素と編集領域はページタップにしない。
    func testInteractiveControlClicksDoNotPostPageTaps() async throws {
        let body = """
            <audio id="audio" controls="controls"></audio>
            <video id="video" controls="controls"></video>
            <button id="button" type="button">ボタン</button>
            <input id="input" type="text" />
            <select id="select"><option>選択肢</option></select>
            <textarea id="textarea">入力欄</textarea>
            <details><summary id="summary">詳細</summary><p>内容</p></details>
            <label for="input"><span id="labelChild">ラベル</span></label>
            <div contenteditable="true"><span id="editableChild">編集可能</span></div>
            <p id="plain">本文</p>
            """
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let defaultsPreserved: Bool = try await harness.evaluate("""
            const ids = ['audio', 'video', 'button', 'input', 'select',
                         'textarea', 'summary', 'labelChild', 'editableChild'];
            return ids.map(id => {
                const event = new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:1,
                    clientX:40, clientY:40, button:0
                });
                document.getElementById(id).dispatchEvent(event);
                return !event.defaultPrevented;
            }).every(Boolean);
            """)
        XCTAssertTrue(defaultsPreserved)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)

        harness.messages.reset()
        let _: Bool = try await harness.evaluate("""
            document.getElementById('plain').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        let receivedPlainTap = try await harness.waitForMessageCount(
            type: "tap", count: 1)
        XCTAssertTrue(receivedPlainTap)
        XCTAssertEqual(harness.messages.count(type: "tap"), 1)
    }

    /// cooViewer-oxr.27: 既定は detail にかかわらず各 click を遅延なしで通知する。
    func testRapidClicksPostOneTapEachImmediately() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let scheduledTimers: Int = try await harness.evaluate("""
            const target = document.getElementById('text');
            const originalSetTimeout = window.setTimeout;
            let scheduledTimers = 0;
            window.setTimeout = function () { scheduledTimers += 1; return 1; };
            try {
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:1,
                    clientX:40, clientY:40, button:0
                }));
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:2,
                    clientX:140, clientY:40, button:0
                }));
                target.dispatchEvent(new MouseEvent('dblclick', {
                    bubbles:true, cancelable:true, detail:2,
                    clientX:140, clientY:40, button:0
                }));
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:0,
                    clientX:0, clientY:0, button:0
                }));
            } finally {
                window.setTimeout = originalSetTimeout;
            }
            return scheduledTimers;
            """)
        XCTAssertEqual(scheduledTimers, 0)
        let receivedRapidTaps = try await harness.waitForMessageCount(
            type: "tap", count: 2)
        XCTAssertTrue(receivedRapidTaps)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 2)
    }

    func testOptInDoubleClickEventDoesNotPostTap() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle(deferTaps: true)
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            document.getElementById('text').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            document.getElementById('text').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:2,
                clientX:40, clientY:40, button:0
            }));
            document.getElementById('text').dispatchEvent(new MouseEvent('dblclick', {
                bubbles:true, cancelable:true, detail:2,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    func testDoubleClickedAnchorPreventsDefaultWithoutDuplicateLink() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(
            bodyHTML: "<a id=\"link\" href=\"#chapter\">章へ</a>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle()
        harness.messages.reset()

        let prevented: String = try await harness.evaluate("""
            const anchor = document.getElementById('link');
            const first = new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1, clientX:40, clientY:40
            });
            const second = new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:2, clientX:40, clientY:40
            });
            anchor.dispatchEvent(first);
            anchor.dispatchEvent(second);
            return `${first.defaultPrevented}|${second.defaultPrevented}`;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(prevented, "true|true")
        XCTAssertEqual(harness.messages.count(type: "link"), 1)
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    func testOptInPlainSingleClickPostsTapAfterDoubleClickWindow() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle(deferTaps: true)
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            document.getElementById('text').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 1)
    }

    func testOptInRapidIndependentSingleClicksBothPostTaps() async throws {
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setupLifecycle(deferTaps: true)
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            const target = document.getElementById('text');
            target.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            target.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:140, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 2)
    }
}
