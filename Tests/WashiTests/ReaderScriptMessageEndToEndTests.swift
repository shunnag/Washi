import AppKit
import WebKit
import XCTest
@testable import Washi

// WP6b: wheelTurn / key / scrollFailure の端から端までの回帰。JS が post した body を
// 記録し、native の橋渡し(EPUBReaderView.handleScriptMessage)まで通して確かめる

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

@MainActor
final class ReaderScriptMessageEndToEndTests: XCTestCase {
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
