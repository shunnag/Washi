import WebKit

/// cooViewer-oxr.88: オフスクリーン描画に使う WebView の共通構成。
@MainActor
enum EPUBOffscreenWebViewConfiguration {
    static func make(allowsScriptedContent: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            allowsScriptedContent
        EPUBScriptedContentHardening.install(
            in: configuration.userContentController,
            allowsScriptedContent: allowsScriptedContent)
        // cooViewer-oxr.88: 不可視の census / thumbnail / rasterizer では、
        // 本文の autoplay が音声・動画を勝手に再生しないよう全媒体を止める。
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        return configuration
    }
}
