import AppKit
import WebKit

/// EPUBReaderView のテーマ(ライト/ダーク)と表示配慮: 実効配色の判定、
/// ネイティブ側と Web コンテンツ側への配色の反映、外観変更の追従。
extension EPUBReaderView {
    // MARK: - テーマ(ライト/ダーク)

    /// 実効ダークか(theme=system はビューの実効外観に追従)
    var isDarkEffective: Bool {
        isDark(for: settings.theme)
    }

    func isDark(for theme: EPUBReaderTheme) -> Bool {
        switch theme {
        case .light: return false
        case .dark: return true
        case .system:
            return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    var shouldIncreaseContrast: Bool {
        accessibilityIncreaseContrastOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var shouldDifferentiateWithoutColor: Bool {
        accessibilityDifferentiateWithoutColorOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        applyThemeCSSOnly()
    }

    /// ネイティブ側(余白の背景・柱・ノンブルの色)へテーマを反映する
    func applyTheme() {
        let colors = settings.effectiveColors(
            isDark: isDarkEffective, increaseContrast: shouldIncreaseContrast)
        layer?.backgroundColor = CSSColorParser.parse(colors.background)
            ?? NSColor.textBackgroundColor.cgColor
        // ノンブルは紙の本らしく控えめなグレー
        let furnitureColor = isDarkEffective
            ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        for label in pageNumberLabels {
            label.textColor = furnitureColor
        }
    }

    /// ページ側(Web コンテンツ)へ配色 CSS だけを差し替える(再ページ割りなし)
    func applyThemeCSSOnly(retakesCover: Bool = true) {
        guard let webView else { return }
        let css = settings.composedUserCSS(
            isDark: isDarkEffective,
            increaseContrast: shouldIncreaseContrast,
            differentiateWithoutColor: shouldDifferentiateWithoutColor)
        // 撮り直しの描画待ちより前に届くよう、Task を挟まずに送る
        webView.callAsyncJavaScript(
            "return __washi.setUserCSS(css);", arguments: ["css": css],
            in: nil, in: WashiContentWorld.world, completionHandler: nil)
        if retakesCover {
            retakePageCoverAfterRestyle()
        } else if pageCover.prefetchedPageCover == nil {
            schedulePageCoverPrefetchAfterFrames()
        }
    }

    /// cooViewer-oxr.27: opt-in 時だけシステムのダブルクリック間隔を JS へ渡す。
    func updateTapDeferral() {
        let enabled = settings.defersTapsForDoubleClick
        let interval = NSEvent.doubleClickInterval
        let milliseconds = 1_000 * (interval > 0 ? interval : 0.5)
        evaluate("__washi.setTapDeferral(\(enabled), \(milliseconds));")
    }

    @objc func accessibilityDisplayOptionsDidChange() {
        // cooViewer-oxr.37: 表示配慮は配色だけを差し替え、census/再ページ割りを
        // 起動しない。テスト override の didSet も同じ経路へ入る。
        applyTheme()
        applyThemeCSSOnly()
        updateAccessibilityMetadata()
    }
}
