import WebKit

/// Washi-hgd: 表示・非表示で硬化設定が食い違わないよう、共通の構成をここに集める。
@MainActor
enum WebViewConfiguration {
    static func makeHardened(allowsScriptedContent: Bool,
                             allowsMediaAutoplay: Bool = false) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // 別の WebView と本の状態を共有しないよう、構築ごとに store を作る。
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            allowsScriptedContent
        // cooViewer-oxr.88: 本を開くだけで音声・動画を再生させない。
        // 朗読は AVAudioPlayer で扱う。画面上では信頼できる本にだけ opt-in できる。
        configuration.mediaTypesRequiringUserActionForPlayback = allowsMediaAutoplay ? [] : .all
        EPUBScriptedContentHardening.install(
            in: configuration.userContentController,
            allowsScriptedContent: allowsScriptedContent)
        return configuration
    }
}
