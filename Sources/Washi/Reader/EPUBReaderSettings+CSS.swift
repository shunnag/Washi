import Foundation

extension EPUBReaderSettings {
    /// テーマの実効配色(ライト = 紙白、ダーク = Apple Books 系の
    /// ほぼ黒 + 明灰文字)。明示指定(backgroundColorCSS 等)が最優先
    func effectiveColors(
        isDark: Bool, increaseContrast: Bool = false
    ) -> (background: String, text: String?) {
        if increaseContrast {
            // cooViewer-oxr.37: システムのコントラスト増加時は著者・host の
            // 中間色より純黒/純白を優先し、背景と本文を同じ経路で決める。
            return isDark ? ("#000000", "#ffffff")
                          : ("#ffffff", "#000000")
        }
        let background = backgroundColor?.cssString
            ?? backgroundColorCSS ?? (isDark ? "#1a1a1c" : "#ffffff")
        let text: String?
        if let explicit = textColor?.cssString ?? textColorCSS {
            text = explicit
        } else if forcesReadableColors {
            // 読みやすさ優先: 本が色を指定していても、テーマ背景に対して確実に
            // 読める文字色を両モードで用意する(Apple Books のダーク相当)
            text = isDark ? "#ececec" : "#1a1a1a"
        } else {
            // 本の配色を尊重: ダークだけ継承用の明灰を用意(本が色指定を持つ
            // ページはそちらが勝つ=本来の見た目のまま)
            text = isDark ? "#d5d5d0" : nil
        }
        return (background, text)
    }

    /// 既定フォントと上書きフォントの設定で共用する CSS 文字列のエスケープ。
    private func escapedFontFamily(_ family: String) -> String {
        let stripped = family.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && $0 != "\u{2028}" && $0 != "\u{2029}"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// fontScale を CSS で上書きせず census/layout key だけへ反映する印。
    /// 実倍率は cooViewer-oxr.60 / cooViewer-oxr.76 の runtime 計測で適用する。
    private func fontScaleKeyCSS() -> String {
        guard fontScale != 1.0 else { return "" }
        return "/* washi-font-scale: \(fontScale) */\n"
    }

    /// cooViewer-oxr.32: namespace 宣言は同じ stylesheet の全規則より前に置く。
    /// aside の非表示は本文量を変えるため、注入 CSS と census key で共用する。
    private func footnoteVisibilityCSS() -> String {
        guard hidesFootnoteAsides else { return "" }
        return """
        @namespace epub url(http://www.idpf.org/2007/ops);
        aside[epub|type~="footnote"], aside[epub|type~="endnote"], aside[epub|type~="rearnote"], aside[role="doc-footnote"], aside[role="doc-endnote"] { display: none !important; }

        """
    }

    /// 著者 stylesheet より前へ挿入する既定フォント CSS。
    /// 最初の cascade layer + :where の詳細度 0 で、cooViewer-oxr.77 の
    /// 「本が常に勝つ」を layered stylesheet に対しても守る。
    func defaultFontCSS() -> String {
        var css = ""
        if let family = defaultFontFamily, !family.isEmpty {
            // !important なし + :where(html) = 継承でしか効かないため、
            // 「本が指定しなかったときだけ」の既定フォントになる。
            // 値は CSS 文字列としてエスケープ(defaults 直書きの任意文字列で
            // 規則が壊れたり CSS が注入されたりしないように)。改行・制御文字は
            // CSS 文字列トークンを終端させ後続を新規規則として注入できてしまう
            // ため、エスケープ前に除去する(U+2028/2029 は controlCharacters に
            // 含まれないので明示除去。CJK フォント名を通すため allowlist は使わない)
            let escaped = escapedFontFamily(family)
            css += "@layer washi-reader-default { :where(html) { font-family: \"\(escaped)\", serif; } }\n"
        }
        return css
    }

    /// cooViewer-oxr.33: 文字組み設定はすべて本文量または字送りを変えるため、
    /// live CSS と census key が同じ文字列を共有する。
    private func typographyCSS() -> String {
        var css = ""
        if let scale = lineHeightScale, scale.isFinite, scale > 0 {
            css += "html { --washi-line-height-scale: \(scale); }\n"
            css += "body * { line-height: calc(var(--washi-line-height-base, 1.6) * var(--washi-line-height-scale)) !important; }\n"
        }
        if let spacing = letterSpacingEm, spacing.isFinite {
            // cooViewer-oxr.33: 縦組みでは字間・単語間を強制しない。
            css += "html:not(.washi-vertical) body, html:not(.washi-vertical) body * { letter-spacing: \(spacing)em !important; }\n"
        }
        if let spacing = paragraphSpacingEm, spacing.isFinite {
            css += "p { margin-block-end: \(spacing)em !important; }\n"
        }
        if let family = fontFamilyOverride, !family.isEmpty {
            let escaped = escapedFontFamily(family)
            css += "body, body *:not(code):not(pre):not(kbd):not(samp) { font-family: \"\(escaped)\", serif !important; }\n"
        }
        if hidesRuby {
            css += "rt, rp { display: none !important; }\n"
        }
        return css
    }

    /// ページ割りに影響する CSS だけを組み立てる(census 用。
    /// 配色はページ数に影響しないため含めない — テーマ切替で census を
    /// 無駄に無効化しないためのキー安定化)
    func layoutAffectingCSS() -> String {
        footnoteVisibilityCSS() + fontScaleKeyCSS() + typographyCSS()
            + (userCSS ?? "")
    }

    /// 注入するユーザー CSS を組み立てる
    func composedUserCSS(
        isDark: Bool, increaseContrast: Bool = false,
        differentiateWithoutColor: Bool = false
    ) -> String {
        var css = footnoteVisibilityCSS() + fontScaleKeyCSS() + typographyCSS()
        let colors = effectiveColors(
            isDark: isDark, increaseContrast: increaseContrast)
        css += ":root { color-scheme: \(isDark ? "dark" : "light"); }\n"
        css += "html { background-color: \(colors.background) !important; }\n"
        // cooViewer-oxr.4: ダークでは本の body の白背景でテーマの地色を覆わない。
        // 本の配色を尊重するライトでは、クリーム色など本来の body 背景を保つ。
        // 読みやすさ優先では両テーマで子孫の不透明背景も除くが、画像等の背景は保つ。
        let readable = increaseContrast
            || (forcesReadableColors && textColor == nil && textColorCSS == nil)
        if readable {
            css += "body, body *:not(img):not(svg):not(image):not(video):not(canvas) { background-color: transparent !important; }\n"
            if isDark {
                // cooViewer-oxr.4: 透明化規則の :not による詳細度も上回る必要がある。
                css += "body :is(pre, code):not(img):not(svg):not(image):not(video):not(canvas) { background-color: #242426 !important; }\n"
            }
        } else if isDark {
            css += "body { background-color: transparent !important; }\n"
        }
        if let text = colors.text {
            if readable {
                // 読みやすさ優先: 本の色指定(class・要素セレクタ等)より強く
                // 上書きして必ず読める色に(!important で継承の壁を越える)。
                // cooViewer-oxr.4: リンクの span/ruby とコードの子孫も除外し、
                // リンクの継承色・コード固有の配色を保つ。
                css += "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *) { color: \(text) !important; }\n"
                css += "a { color: \(isDark ? "#7fb2ff" : "#1a56db") !important; }\n"
            } else {
                // 本の配色を尊重: body への継承指定のみ(本文が色指定を持つ本は
                // そちらが勝つ)。リンクはダークで読める青へ
                css += "body { color: \(text); }\n"
                if isDark {
                    css += "a { color: #7fb2ff; }\n"
                }
            }
        }
        if isDark {
            // cooViewer-oxr.78: 写真や挿絵を反転せず、JS が字形と判定した
            // 小さなインライン画像だけを対象にする。filter は配色だけを変え、
            // 版面寸法には影響しない。
            if invertsGlyphImagesInDark {
                css += "img.washi-glyph { filter: invert(1) !important; }\n"
            }
            // cooViewer-oxr.78: fill 未指定の最外 SVG だけを currentColor へ
            // 揃え、子孫へ継承させる。子要素へ直接指定すると祖先の fill="none"
            // や明示色を上書きするため、入れ子 SVG も祖先色をそのまま継承する。
            let strength = readable ? " !important" : ""
            css += ":where(svg:not(svg *):not([fill]):not([style*=\"fill\" i])) { fill: currentColor\(strength); }\n"
            css += ":where(svg:is([stroke=\"black\" i], [stroke=\"#000\" i], [stroke=\"#000000\" i]), svg :is([stroke=\"black\" i], [stroke=\"#000\" i], [stroke=\"#000000\" i])) { stroke: currentColor\(strength); }\n"
        }
        if differentiateWithoutColor {
            // cooViewer-oxr.37: 色だけに依存せずリンクを識別できるようにする。
            css += "a { text-decoration: underline !important; }\n"
        }
        if let extra = userCSS {
            css += extra
        }
        return css
    }
}
