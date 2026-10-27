import WebKit

/// cooViewer-oxr.88: オフスクリーン描画に使う WebView の共通構成。
@MainActor
enum EPUBOffscreenWebViewConfiguration {
    static func make(allowsScriptedContent: Bool) -> WKWebViewConfiguration {
        let configuration = WebViewConfiguration.makeHardened(
            allowsScriptedContent: allowsScriptedContent)
        configuration.suppressesIncrementalRendering = true
        return configuration
    }
}
