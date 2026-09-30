import AppKit
import JavaScriptCore
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class RenderingLifecycleMessageRecorder: NSObject, WKScriptMessageHandler {
    private(set) var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            messages.append(body)
        }
    }

    func reset() {
        messages.removeAll()
    }

    func count(type: String) -> Int {
        messages.count { $0["type"] as? String == type }
    }

    func compactMap<T>(_ transform: ([String: Any]) -> T?) -> [T] {
        messages.compactMap(transform)
    }

    func first(type: String) -> [String: Any]? {
        messages.first { $0["type"] as? String == type }
    }
}

/// `didReceiveKey` だけを記録する delegate。JS が post した body をそのまま
/// EPUBReaderView.handleScriptMessage へ流し、EPUBKeyEvent への写像を確かめる
@MainActor
private final class KeyEventSpy: EPUBReaderViewDelegate {
    private(set) var keys: [EPUBKeyEvent] = []

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        keys.append(event)
    }
}

/// 連続スクロール文書(EPUBScrollDocument)を実 WKWebView で動かすハーネス。
/// ReaderScriptHarness と同じ箱・非永続ストア・EPUBSchemeHandler に、本番と同じ
/// EPUBScrollDocument.install の user script(コンテナには continuousScrollScript、
/// 章 iframe には pageScript)を組み、"washi" メッセージを記録する。
@MainActor
private final class ContinuousScrollHarness {
    let window: NSWindow
    let webView: WKWebView
    let messages = RenderingLifecycleMessageRecorder()
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler
    /// コンテナ読み込みの待ち手。navigationDelegate は weak で、本番では
    /// EPUBReaderView 自身が務める。章 iframe の読み込みは delegate が生きて
    /// いる間しか完了しない(実測)ので、`close()` まで保持する
    private var navigationWaiter: NavigationWaiter?

    init(bodyHTML: String, size: NSSize = NSSize(width: 640, height: 400)) throws {
        publication = try EPUBFixtures.publication(
            EPUBFixtures.singleSpineEntries(bodyHTML: bodyHTML), name: "washi-scroll-harness")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        schemeHandler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        let controller = configuration.userContentController
        controller.add(messages, contentWorld: WashiContentWorld.world, name: "washi")
        EPUBScrollDocument.install(in: controller, handler: schemeHandler)
        webView = WKWebView(
            frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = makeOffscreenWindow(containing: webView)
    }

    /// 章 iframe に読ませる、読書順先頭項目の URL
    var chapterURL: URL {
        get throws {
            try XCTUnwrap(schemeHandler.url(
                forReadingOrderItem: XCTUnwrap(publication.readingOrder.first)))
        }
    }

    /// コンテナ文書を読み込む。完了しなければ CI では失敗・ローカルでは skip
    func loadScrollDocumentForLifecycleTest(file: StaticString = #filePath,
                                            line: UInt = #line) async throws {
        do {
            let url = try XCTUnwrap(schemeHandler.scrollDocumentURL)
            let waiter = NavigationWaiter()
            navigationWaiter = waiter
            webView.navigationDelegate = waiter
            webView.load(URLRequest(url: url))
            try await waiter.wait(timeout: .seconds(15))
        } catch {
            try failOrSkipWebKitTest("連続スクロール文書の読み込みが完了しませんでした: \(error)",
                                     file: file, line: line)
            throw error
        }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        navigationWaiter = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "washi", contentWorld: WashiContentWorld.world)
        window.contentView = nil
        window.close()
    }

    func evaluate<T: Sendable>(_ body: String, as type: T.Type = T.self) async throws -> T {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                body, in: nil, contentWorld: WashiContentWorld.world)
            return try XCTUnwrap(result as? T)
        }.value
    }

    func settleMessages() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    func waitForMessage(type: String) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) > 0 { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

extension ReaderScriptHarness {
    /// "washi" メッセージを RenderingLifecycleMessageRecorder で記録するハーネスを組む
    fileprivate static func renderingLifecycle(bodyHTML: String) throws -> ReaderScriptHarness {
        try ReaderScriptHarness(
            bodyHTML: bodyHTML,
            messageHandler: (name: "washi", handler: RenderingLifecycleMessageRecorder()))
    }

    /// `renderingLifecycle(bodyHTML:)` で登録した記録係
    fileprivate var messages: RenderingLifecycleMessageRecorder {
        guard let recorder = scriptMessageHandler as? RenderingLifecycleMessageRecorder else {
            preconditionFailure("renderingLifecycle(bodyHTML:) で組んだハーネスだけが messages を持つ")
        }
        return recorder
    }

    /// ライフサイクル検証用の setup(タップ保留と doubleClickDelayMS を含む)。
    /// `documentToken` を渡すと JS が post する各メッセージの `token` に載る
    fileprivate func setupLifecycle(spread: Bool = false, keysEnabled: Bool = false,
                                    fixedLayout: Bool = false,
                                    deferTaps: Bool = false,
                                    documentToken: String? = nil) async throws {
        let token = documentToken.map { "documentToken:'\($0)'," } ?? ""
        let _: Int = try await evaluate("""
            const result = __washi.setup({width:640,height:400,gap:24,
                spread:\(spread),gutter:48,fixedLayout:\(fixedLayout),
                keysEnabled:\(keysEnabled),deferTaps:\(deferTaps),\(token)
                doubleClickDelayMS:250,userCSS:''});
            return result.pageCount;
            """)
    }

    /// WebKit のナビゲーションが完了しなければ、既存の慣例どおり CI では失敗・
    /// ローカルでは skip にして打ち切る
    fileprivate func loadForLifecycleTest(file: StaticString = #filePath,
                                          line: UInt = #line) async throws {
        do {
            try await load()
        } catch {
            try failOrSkipWebKitTest("WKWebView の読み込みが完了しませんでした: \(error)",
                                     file: file, line: line)
            throw error
        }
    }

    fileprivate func settleMessages() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    fileprivate func waitForMessage(type: String) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) > 0 { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    fileprivate func waitForMessageCount(type: String, count: Int) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) >= count { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// cooViewer-oxr.23/24/25/26/27/48/81/82: ReaderScripts のライフサイクル回帰。
@MainActor
final class ReaderScriptsRenderingLifecycleTests: XCTestCase {
    /// 生成された JS を簡易 DOM 上で実行し、著者の同名 id を書き換えずに
    /// 内部 style を作成・再利用することを検証する。WebKit の描画は不要。
    func testGeneratedStyleScriptPreservesAuthorIDCollisions() throws {
        for (tag, marked, hasDataset) in [
            ("div", false, true), ("style", false, true),
            ("div", true, true), ("style", false, false),
        ] {
            let context = try makeStyleScriptContext()
            let result = context.evaluateScript("""
                const ids = ['washi-base', 'washi-pagination', 'washi-user',
                             'washi-font-scale', 'washi-default-font'];
                const authors = ids.map(id => {
                    const author = document.createElement('\(tag)');
                    author.id = id;
                    author.textContent = '著者の内容';
                    if (\(marked)) { author.dataset.washiOwned = '1'; }
                    if (!\(hasDataset)) { delete author.dataset; }
                    document.head.appendChild(author);
                    return author;
                });
                const preserved = authors.every(author => {
                    const owned = __washi.styleTest.ensureStyle(author.id);
                    owned.textContent = 'html { color: red; }';
                    return owned !== author && owned.localName === 'style'
                        && owned.dataset.washiOwned === '1'
                        && owned.id === author.id
                        && __washi.styleTest.ensureStyle(author.id) === owned
                        && author.textContent === '著者の内容'
                        && author.parentNode === document.head;
                });
                __washi.styleTest.installDefaultFontCSS('html { font-family: serif; }');
                __washi.styleTest.installDefaultFontCSS('html { font-family: sans-serif; }');
                const font = __washi.styleTest.findOwnedStyle('washi-default-font');
                preserved && authors.every(author => author.textContent === '著者の内容')
                    && font.textContent === 'html { font-family: sans-serif; }'
                    && document.querySelectorAll('style[data-washi-owned="1"]').length === ids.length;
                """)
            XCTAssertNil(context.exception, "\(tag), \(marked): \(String(describing: context.exception))")
            XCTAssertTrue(try XCTUnwrap(result).toBool(), "\(tag), \(marked)")
        }
    }

    /// 基礎 CSS の起動スクリプトも同じ出自判定を行い、著者要素を移動しない。
    /// 再注入しても自前の要素は一つだけに保つ。
    func testGeneratedBaseCSSInjectorPreservesAuthorIDCollisions() throws {
        for (tag, marked, hasDataset) in [
            ("div", false, true), ("style", false, true),
            ("div", true, true), ("style", false, false),
        ] {
            let context = try makeStyleScriptContext()
            context.evaluateScript("""
                const author = document.createElement('\(tag)');
                author.id = 'washi-base';
                author.textContent = '著者の内容';
                if (\(marked)) { author.dataset.washiOwned = '1'; }
                if (!\(hasDataset)) { delete author.dataset; }
                document.body.appendChild(author);
                """)
            context.evaluateScript(ReaderScripts.baseCSSInjector)
            XCTAssertNil(context.exception)
            context.evaluateScript(ReaderScripts.baseCSSInjector)
            let result = context.evaluateScript("""
                const owned = document.head.firstChild;
                owned !== author && owned.localName === 'style'
                    && owned.id === 'washi-base' && owned.dataset.washiOwned === '1'
                    && owned.textContent.includes('@font-face')
                    && author.textContent === '著者の内容'
                    && author.parentNode === document.body
                    && document.head.children.length === 1;
                """)
            XCTAssertNil(context.exception, "\(tag), \(marked): \(String(describing: context.exception))")
            XCTAssertTrue(try XCTUnwrap(result).toBool(), "\(tag), \(marked)")
        }
    }

    private func makeStyleScriptContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        // 必要な DOM 操作だけを実装する。イベント登録は受け付けるが発火しない。
        context.evaluateScript(#"""
            class Element {
                constructor(name) {
                    this.localName = name;
                    this.namespaceURI = 'http://www.w3.org/1999/xhtml';
                    this.id = '';
                    this.dataset = {};
                    this.textContent = '';
                    this.parentNode = null;
                    this.children = [];
                }
                get firstChild() { return this.children[0] || null; }
                get nextSibling() {
                    if (!this.parentNode) { return null; }
                    const siblings = this.parentNode.children;
                    return siblings[siblings.indexOf(this) + 1] || null;
                }
                appendChild(el) { return this.insertBefore(el, null); }
                insertBefore(el, next) {
                    if (el === next) { return el; }
                    if (el.parentNode) {
                        const previous = el.parentNode.children;
                        previous.splice(previous.indexOf(el), 1);
                    }
                    const index = next ? this.children.indexOf(next) : this.children.length;
                    this.children.splice(index, 0, el);
                    el.parentNode = this;
                    return el;
                }
                getAttribute(name) {
                    return name === 'data-washi-owned' ? this.dataset?.washiOwned || null : null;
                }
                setAttribute(name, value) {
                    if (name === 'data-washi-owned') { this.dataset.washiOwned = value; }
                }
            }
            var window = this;
            window.addEventListener = function () {};
            window.setTimeout = function () { return 1; };
            window.clearTimeout = function () {};
            var document = {
                head: new Element('head'), body: new Element('body'),
                createElement: name => new Element(name),
                createElementNS(namespace, name) {
                    const el = new Element(name);
                    el.namespaceURI = namespace;
                    return el;
                },
                addEventListener() {}, removeEventListener() {},
                getElementById(id) {
                    return [...this.head.children, ...this.body.children]
                        .find(el => el.id === id) || null;
                },
                querySelectorAll(selector) {
                    if (selector !== 'style[data-washi-owned="1"]') {
                        throw new Error('未対応の selector: ' + selector);
                    }
                    return [...this.head.children, ...this.body.children].filter(el =>
                        el.localName === 'style' && el.dataset?.washiOwned === '1');
                }
            };
            """#)
        // 生成物をそのまま評価し、非公開関数への入口だけをテスト内で追加する。
        let script = ReaderScripts.pageScript.replacingOccurrences(
            of: "window.__washi = washi;", with: """
                window.__washi = washi;
                washi.styleTest = { ensureStyle, findOwnedStyle, installDefaultFontCSS };
                """)
        context.evaluateScript(script)
        XCTAssertNil(context.exception, String(describing: context.exception))
        return context
    }

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

    // MARK: - WP6b: wheelTurn / key / scrollFailure の端から端までの回帰

    /// `wheelTurn` を固定する: ページ送り表示でホイール/トラックパッドの蓄積が
    /// 閾値(50)を超えると、生の方向 `forward` と軸 `horizontal`(いずれも
    /// Bool)を 1 ジェスチャ 1 回だけ通知し、ラッチ中の追加イベントは通知しない。
    /// 綴じ方向への変換は native(turnPageLeft/Right・goForward)が担う。
    func testWheelGesturePostsWheelTurnWithDirectionAndAxis() async throws {
        let wheelTurn = EPUBScriptMessage.wheelTurn.rawValue
        let body = (0..<40).map { "<p>ホイール操作の本文 \($0) です。</p>" }.joined()
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: body)
        defer { harness.close() }
        try await harness.loadForLifecycleTest()
        try await harness.setupLifecycle(documentToken: "wp6b-wheel")
        harness.messages.reset()

        let prevented: String = try await harness.evaluate("""
            const quiet = () => new Promise(r => setTimeout(r, 300));
            const wheel = (deltaX, deltaY) => {
                const event = new WheelEvent('wheel', {
                    deltaX, deltaY, bubbles:true, cancelable:true
                });
                document.dispatchEvent(event);
                return event.defaultPrevented;
            };
            // 文書ロード直後のラッチ(250ms の静穏まで)が解けるのを待ってから、
            // 下方向のジェスチャ、ラッチ中の追加イベント、静穏後の左方向の
            // ジェスチャ(水平が優勢)の順に送る
            await quiet();
            const results = [wheel(0, 60), wheel(0, 60)];
            await quiet();
            results.push(wheel(-60, 10));
            return results.join('|');
            """)
        XCTAssertEqual(prevented, "true|true|true", "ページ送り表示の wheel は既定動作を止める")
        let received = try await harness.waitForMessageCount(type: wheelTurn, count: 2)
        XCTAssertTrue(received)
        try await harness.settleMessages()

        let turns = harness.messages.messages.filter { $0["type"] as? String == wheelTurn }
        XCTAssertEqual(turns.count, 2, "ラッチ中の追加イベントで余分に通知した")
        // native は forward / horizontal を `as? Bool` で読む(EPUBReaderView+ScriptBridge)
        let directions = turns.map { message -> String in
            let forward = (message["forward"] as? Bool).map(String.init(describing:)) ?? "nil"
            let horizontal = (message["horizontal"] as? Bool).map(String.init(describing:)) ?? "nil"
            return "\(forward)/\(horizontal)"
        }
        XCTAssertEqual(directions, ["true/false", "false/true"])
        XCTAssertEqual(turns.map { $0["token"] as? String }, ["wp6b-wheel", "wp6b-wheel"])
    }

    /// `key` を固定する: keysEnabled が false(ホストがキーを扱う)のとき、
    /// 矢印キーの keydown を key・code(String)と shift・alt・ctrl・meta(Bool)
    /// とともに通知して既定動作を止め、native は EPUBKeyEvent
    /// (alt→option、ctrl→control、meta→command)へ写す。keysEnabled が true なら
    /// JS 自身がめくりを扱い、key は通知しない。
    func testArrowKeydownPostsKeyOnlyWhenKeysDisabled() async throws {
        let key = EPUBScriptMessage.key.rawValue
        let reader = EPUBReaderView(frame: .zero)
        let spy = KeyEventSpy()
        reader.delegate = spy
        let harness = try ReaderScriptHarness.renderingLifecycle(bodyHTML: "<p>矢印キー</p>")
        defer { harness.close() }
        try await harness.loadForLifecycleTest()
        // 表示中の文書からの通知として受理されるよう、リーダーの印を setup に渡す
        try await harness.setupLifecycle(keysEnabled: false,
                                         documentToken: reader.currentDocumentToken)
        harness.messages.reset()

        let dispatchArrowRight = """
            const event = new KeyboardEvent('keydown', {
                key:'ArrowRight', code:'ArrowRight', shiftKey:true, metaKey:true,
                bubbles:true, cancelable:true
            });
            document.dispatchEvent(event);
            return event.defaultPrevented;
            """
        let forwarded: Bool = try await harness.evaluate(dispatchArrowRight)
        XCTAssertTrue(forwarded, "転送した矢印キーは既定動作を止める")
        let received = try await harness.waitForMessage(type: key)
        XCTAssertTrue(received)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: key), 1)
        let message = try XCTUnwrap(harness.messages.first(type: key))
        XCTAssertEqual(message["key"] as? String, "ArrowRight")
        XCTAssertEqual(message["code"] as? String, "ArrowRight")
        XCTAssertEqual(message["shift"] as? Bool, true)
        XCTAssertEqual(message["alt"] as? Bool, false)
        XCTAssertEqual(message["ctrl"] as? Bool, false)
        XCTAssertEqual(message["meta"] as? Bool, true)
        XCTAssertEqual(message["token"] as? String, reader.currentDocumentToken)

        // 記録した body をそのまま Swift 側の橋渡しへ流す
        reader.handleScriptMessage(message)
        XCTAssertEqual(spy.keys, [EPUBKeyEvent(key: "ArrowRight", code: "ArrowRight",
                                               shift: true, option: false,
                                               control: false, command: true)])

        try await harness.setupLifecycle(keysEnabled: true,
                                         documentToken: reader.currentDocumentToken)
        harness.messages.reset()
        let handledByScript: Bool = try await harness.evaluate(dispatchArrowRight)
        XCTAssertTrue(handledByScript, "JS がめくりとして処理し既定動作を止める")
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: key), 0)
        XCTAssertEqual(spy.keys.count, 1)
    }

    /// `scrollFailure` を固定する: 連続スクロール文書が準備完了(ready)後の
    /// 遅延読み込みで章 iframe を取り付けられなかったときだけ、`reason`(String)を
    /// 添えて 1 回通知する(同じ章の再失敗は通知しない)。準備中の失敗は setup の
    /// 拒否で伝えるので、この通知は出さない。`spineIndex` は付けない
    /// (native の spine 番号ゲートを通らずに didFailWith へ届く)。
    func testContinuousScrollLazyLoadFailurePostsScrollFailureOnce() async throws {
        let scrollFailure = EPUBScriptMessage.scrollFailure.rawValue
        let harness = try ContinuousScrollHarness(bodyHTML: "<p>連続スクロールの章</p>")
        defer { harness.close() }
        try await harness.loadScrollDocumentForLifecycleTest()
        let chapterURL = try harness.chapterURL.absoluteString

        // roll 章だけの文書: 表示中の章は setup で読み込み、2 画面(800px)より
        // 先の章は枠だけにしてスクロール時に遅延読み込みする。2 章目は描画不能。
        let ready: Bool = try await harness.evaluate("""
            const result = await __washi.setup({width:640,height:400,gap:24,spread:false,
                gutter:48,fixedLayout:false,flow:'scrolled-continuous',keysEnabled:false,
                userCSS:'',documentToken:'wp6b-scroll',spineIndex:0,
                continuousItems:[
                    {index:0,url:'\(chapterURL)',roll:true,renderable:true,
                     width:640,height:4000},
                    {index:1,url:'\(chapterURL)',roll:true,renderable:false,
                     width:640,height:400}
                ]});
            const metrics = __washi.scrollMetrics();
            return metrics.ready && result.pageCount > 0
                && metrics.items[0].loaded && !metrics.items[1].loaded;
            """)
        XCTAssertTrue(ready, "1 章目だけを読み込んで準備完了になる")
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: scrollFailure), 0,
                       "準備中は scrollFailure を出さない")
        harness.messages.reset()

        // 1 章目の末尾へ進めると 2 章目が読み込み範囲に入り、遅延読み込みが失敗する
        let _: Bool = try await harness.evaluate("""
            __washi.showProgression(1);
            return true;
            """)
        let received = try await harness.waitForMessage(type: scrollFailure)
        XCTAssertTrue(received)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: scrollFailure), 1)
        let message = try XCTUnwrap(harness.messages.first(type: scrollFailure))
        // native は reason を `as? String` で読み、EPUBError.malformed に載せる
        let reason = try XCTUnwrap(message["reason"] as? String)
        XCTAssertTrue(reason.contains("1"), "失敗した章の番号を含む: \(reason)")
        XCTAssertEqual(message["token"] as? String, "wp6b-scroll")
        XCTAssertNil(message["spineIndex"])

        // 同じ章へ再び近づいても、失敗済みの章は読み直さず通知も重ねない
        harness.messages.reset()
        let _: Bool = try await harness.evaluate("""
            __washi.showProgression(0);
            __washi.showProgression(1);
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: scrollFailure), 0)
    }
}
