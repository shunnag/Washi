import AppKit
import WebKit
import XCTest
@testable import Washi

/// ページネーションの物理座標を実 WKWebView で測る共通ハーネス。
/// cooViewer-oxr.56 / cooViewer-oxr.57 / cooViewer-oxr.61
@MainActor
final class PaginationGeometryHarness {
    let window: NSWindow
    let webView: WKWebView
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler

    init(bodyHTML: String, size: NSSize, htmlDirection: String? = nil,
         headCSS: String = "") throws {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: bodyHTML)
        if let htmlDirection {
            entries = try EPUBFixtures.replacing(
                entries, in: "OEBPS/text/c.xhtml", of: "xml:lang=\"ja\">",
                with: "xml:lang=\"ja\" dir=\"\(htmlDirection)\">")
        }
        if !headCSS.isEmpty {
            entries = try EPUBFixtures.replacing(
                entries, in: "OEBPS/text/c.xhtml", of: "</head>",
                with: "<style>\(headCSS)</style></head>")
        }
        publication = try EPUBFixtures.publication(entries, name: "washi-pagination-geometry")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        schemeHandler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        for source in [ReaderScripts.pageScript, ReaderScripts.baseCSSInjector] {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: WashiContentWorld.world))
        }
        webView = WKWebView(
            frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = makeOffscreenWindow(containing: webView)
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
}

// cooViewer-oxr.3 / cooViewer-oxr.5 / cooViewer-oxr.6: 実際の setup を呼ぶ
// オフスクリーン環境。描画フレーム通知に依存せず、非表示ウインドウでも計測する。
@MainActor
final class ReaderScriptTestHarness {
    let window: NSWindow
    let webView: WKWebView
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler

    init(entries: [(name: String, data: Data)]) throws {
        let publication = try EPUBFixtures.publication(entries, name: "washi-batch3")
        self.publication = publication
        let size = NSSize(width: 640, height: 400)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        schemeHandler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        for source in [ReaderScripts.pageScript, ReaderScripts.baseCSSInjector] {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: WashiContentWorld.world))
        }
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = makeOffscreenWindow(containing: webView)
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

    func setup() async throws -> [String: Double] {
        try await evaluate("""
            const s = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return {imagePage: Number(s.imagePage), pageCount:s.pageCount,
                    pagesPerScreen:s.pagesPerScreen, verticalRL:Number(s.mode === 'vrl')};
            """)
    }
}
