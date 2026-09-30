import AppKit
import WebKit

/// 画面外描画に使う不可視ウインドウと WKWebView の寿命を 1 箇所で管理する。
/// WKWebView はウインドウ外では描画が止まるため、画面外の枠なしウインドウ
/// (一度も表示しない)に載せる(macOS で動作が実証された唯一の方法)。
/// ラスタライザ・census・サムネイルレンダラが共用し、構築・読み込み・
/// 解放の順序は各所有者が個別に持っていたものをそのまま保つ。
///
/// 所有者ごとの違いは引数で表す: scheme handler の作り方(ラスタライザは
/// init で作った 1 つを使い続け、census / サムネイルは構築のたびに作る)、
/// user script の注入、読み込みタイムアウト(30 秒 / 15 秒)。
@MainActor
final class EPUBOffscreenWebViewHost {
    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    /// 現在の WKWebView に登録した scheme handler(構築のたびに差し替わる)。
    private(set) var schemeHandler: EPUBSchemeHandler?
    // navigationDelegate は弱参照なので、解決後も保持して外部遷移を遮断する。
    private var pendingNavigationWaiter: NavigationWaiter?
    private var configuredAllowsScriptedContent: Bool?

    /// cooViewer-oxr.68: 所有者の診断用。release 後は false になり、次の
    /// prepare を通ると再び true になる。
    var hasLiveWebView: Bool { webView != nil }

    /// `__washi.setup(options)` の応答のうち、所有者が使う部分。
    struct SetupResult: Sendable {
        let pageCount: Int?
    }

    /// 不可視ウインドウと WKWebView を必要に応じて構築する。著者スクリプト
    /// 許可が前回と違えば WKWebView だけを作り直す(ウインドウは保つ)。
    /// 戻り値は、その作り直しで既存の WKWebView を捨てたかどうか。
    @discardableResult
    func prepare(
        size: NSSize, allowsScriptedContent: Bool,
        makeSchemeHandler: () -> EPUBSchemeHandler,
        installUserScripts: ((WKUserContentController, EPUBSchemeHandler) -> Void)? = nil
    ) -> Bool {
        var didDiscardWebView = false
        if let configuredAllowsScriptedContent,
           configuredAllowsScriptedContent != allowsScriptedContent {
            // cooViewer-oxr.75: WebKit の著者スクリプト設定は構成後に変えられない。
            // 著者スクリプト許可が変われば、構成が不変の WKWebView と
            // scheme handler を同じ条件で作り直す。
            pendingNavigationWaiter?.cancel()
            pendingNavigationWaiter = nil
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
            schemeHandler = nil
            self.configuredAllowsScriptedContent = nil
            didDiscardWebView = true
        }
        if window == nil {
            // 画面外・非表示・クリックされないウインドウ(orderFront はしない。
            // ウインドウに載っていること自体が WebKit の描画ブロック解除条件)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            self.window = window
        }
        if webView == nil {
            let handler = makeSchemeHandler()
            schemeHandler = handler
            let configuration = EPUBOffscreenWebViewConfiguration.make(
                allowsScriptedContent: allowsScriptedContent)
            configuration.setURLSchemeHandler(handler,
                                              forURLScheme: EPUBSchemeHandler.scheme)
            // メッセージハンドラは登録しない: setup() は post しない。
            // wheel/click 等の post 経路は不可視ウインドウでは発火しない
            installUserScripts?(configuration.userContentController, handler)
            let webView = WKWebView(frame: NSRect(origin: .zero, size: size),
                                    configuration: configuration)
            window?.contentView = webView
            self.webView = webView
            configuredAllowsScriptedContent = allowsScriptedContent
        }
        return didDiscardWebView
    }

    /// ウインドウと WKWebView を同寸にそろえる(本番の contentFrame と同寸に
    /// 保つことが innerWidth/Height 一致 = ページ割り一致の前提)。
    func setContentSize(_ size: NSSize) {
        window?.setContentSize(size)
        webView?.frame = NSRect(origin: .zero, size: size)
    }

    /// URL を読み込み、didFinish / didFail を待つ。キャンセル時は読み込みを
    /// 止めてから投げ直す。
    func load(url: URL, timeout: Duration) async throws {
        guard let webView else { throw EPUBPageRasterizer.RasterizeError.loadFailed }
        try await load(url: url, timeout: timeout, in: webView)
    }

    private func load(url: URL, timeout: Duration, in webView: WKWebView) async throws {
        let waiter = NavigationWaiter()
        pendingNavigationWaiter = waiter
        webView.navigationDelegate = waiter
        waiter.expect(webView.load(URLRequest(url: url)))
        // オフスクリーンの WebContent プロセスはジェットサム候補のため、
        // 落ちた/固まったときに永久待ちしないようタイムアウト付きで待つ
        do {
            try await waiter.wait(timeout: timeout)
        } catch {
            if error is CancellationError || Task.isCancelled {
                webView.stopLoading()
            }
            throw error
        }
    }

    /// 読み込んでから、本番と同じ `__washi.setup(options)` を WashiContentWorld
    /// で呼ぶ(census / サムネイル用)。読み込み失敗は投げ、setup の
    /// 期限切れ・キャンセルは nil、JS 側の失敗は `.failure` で返す。
    /// 本番の runSetup と同タイミング(didFinish 直後)で測ることで、
    /// フォント・画像の遅延読み込みによる誤差の出方まで揃える
    func loadAndSetup(
        url: URL, optionsJSON: String, timeout: Duration,
        timeoutScheduler: EPUBOffscreenIdleReleaseTimer.Scheduler =
            EPUBOffscreenIdleReleaseTimer.continuousScheduler
    ) async throws -> Result<SetupResult, any Error>? {
        guard let webView else { throw EPUBPageRasterizer.RasterizeError.loadFailed }
        try await load(url: url, timeout: timeout, in: webView)
        if Task.isCancelled { return nil }
        return await waitForOffscreenResult(
            timeoutScheduler: timeoutScheduler
        ) { completion in
            webView.callAsyncJavaScript(
                "return __washi.setup(\(optionsJSON));",
                arguments: [:], in: nil, in: WashiContentWorld.world,
                completionHandler: { result in
                    completion(result.map {
                        SetupResult(pageCount: ($0 as? [String: Any])?["pageCount"] as? Int)
                    })
                })
        }
    }

    /// 画面外のリソース(不可視 NSWindow と WebContent プロセス)を畳む。
    /// 順序は変えないこと(cooViewer-oxr.53/62、Washi-cfm)。
    func release() {
        // cooViewer-oxr.53/62: delegate を外す前に現在の待機を解決し、
        // 15/30 秒タイムアウトを待たず FIFO と要求を終了させる。
        pendingNavigationWaiter?.cancel()
        pendingNavigationWaiter = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        // NSWindow の解放は AppKit の都合で遅れうるので、WebView をウインドウから
        // 外してから手放す(WebView と WebContent プロセスの寿命をウインドウに預けない)
        window?.contentView = nil
        webView = nil
        schemeHandler = nil
        configuredAllowsScriptedContent = nil
        window?.orderOut(nil)
        window = nil
    }
}
