import AppKit
import WebKit
import XCTest
@testable import Washi

/// ReaderScripts を実 WKWebView で動かす共通ハーネス。ページネーションの物理座標・
/// 画像ページの配置・pagination CSS の cascade・描画ライフサイクルのテストが共有する。
/// cooViewer-oxr.3 / cooViewer-oxr.5 / cooViewer-oxr.6 / cooViewer-oxr.56 /
/// cooViewer-oxr.57 / cooViewer-oxr.61
///
/// 画面外ウインドウに置いた WKWebView に、非永続ストア・本文スクリプト無効・
/// EPUBSchemeHandler・pageScript と baseCSSInjector(WashiContentWorld)を組み、
/// 描画フレーム通知に依存せず非表示ウインドウでも計測する。
@MainActor
final class ReaderScriptHarness {
    let window: NSWindow
    let webView: WKWebView
    /// WebView の箱の大きさ(viewport に合わせた setup の入力に使う)
    let size: NSSize
    /// `messageHandler` で登録した受信側(登録しなければ nil)
    let scriptMessageHandler: (any WKScriptMessageHandler)?
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler
    private let messageHandlerName: String?

    /// `messageHandler` を渡すと、user script より先に WashiContentWorld へ
    /// その名前で登録し、`close()` で外す
    init(entries: [(name: String, data: Data)],
         size: NSSize = NSSize(width: 640, height: 400),
         messageHandler: (name: String, handler: any WKScriptMessageHandler)? = nil) throws {
        publication = try EPUBFixtures.publication(entries, name: "washi-script-harness")
        self.size = size
        scriptMessageHandler = messageHandler?.handler
        messageHandlerName = messageHandler?.name
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        schemeHandler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        let controller = configuration.userContentController
        if let messageHandler {
            controller.add(messageHandler.handler, contentWorld: WashiContentWorld.world,
                           name: messageHandler.name)
        }
        for source in [ReaderScripts.pageScript, ReaderScripts.baseCSSInjector] {
            controller.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: WashiContentWorld.world))
        }
        webView = WKWebView(
            frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = makeOffscreenWindow(containing: webView)
    }

    /// 単一 spine の最小 EPUB を本文 `bodyHTML` で組む。`htmlDirection` は html の dir、
    /// `headCSS` は head 末尾の `<style>`(`headStyleID` を渡すとその id を付ける)
    convenience init(bodyHTML: String,
                     size: NSSize = NSSize(width: 640, height: 400),
                     htmlDirection: String? = nil,
                     headCSS: String = "", headStyleID: String? = nil,
                     messageHandler: (name: String, handler: any WKScriptMessageHandler)? = nil
    ) throws {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: bodyHTML)
        if let htmlDirection {
            entries = try EPUBFixtures.replacing(
                entries, in: "OEBPS/text/c.xhtml", of: "xml:lang=\"ja\">",
                with: "xml:lang=\"ja\" dir=\"\(htmlDirection)\">")
        }
        if !headCSS.isEmpty {
            let openTag = headStyleID.map { "<style id=\"\($0)\">" } ?? "<style>"
            entries = try EPUBFixtures.replacing(
                entries, in: "OEBPS/text/c.xhtml", of: "</head>",
                with: "\(openTag)\(headCSS)</style></head>")
        }
        try self.init(entries: entries, size: size, messageHandler: messageHandler)
    }

    func load() async throws {
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(schemeHandler.url(forReadingOrderItem: entry))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        try await waiter.wait(timeout: .seconds(15))
        withExtendedLifetime(waiter) {}
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        if let messageHandlerName {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: messageHandlerName, contentWorld: WashiContentWorld.world)
        }
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

    /// 物理座標の検証用: viewport と綴じ代を指定して setup し、ページ数と方向を返す
    /// (PaginationGeometryTests / TrailingSpreadPageTests)
    func setup(width: Int, height: Int, spread: Bool,
               gutter: Int = 48, gap: Int = 24) async throws -> [String: Double] {
        try await evaluate("""
            const result = __washi.setup({width:\(width),height:\(height),gap:\(gap),
                spread:\(spread),gutter:\(gutter),fixedLayout:false,
                keysEnabled:false,userCSS:''});
            return {pageCount:result.pageCount,
                    paddedPageCount:result.paddedPageCount,
                    pagesPerScreen:result.pagesPerScreen,
                    firstPageOnRight:Number(result.firstPageOnRight),
                    horizontal:Number(result.mode === 'htb'),
                    verticalRL:Number(result.mode === 'vrl')};
            """)
    }

    /// 640x400 の見開きで setup し、画像ページ判定とページ数と縦組みを返す
    /// (ImagePageLayoutTests / VerticalSpreadPagingTests)
    func setup() async throws -> [String: Double] {
        try await evaluate("""
            const s = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return {imagePage: Number(s.imagePage), pageCount:s.pageCount,
                    pagesPerScreen:s.pagesPerScreen, verticalRL:Number(s.mode === 'vrl')};
            """)
    }
}
