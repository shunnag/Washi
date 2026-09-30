import Foundation

/// 出版物の文書走査で共有する XMLElement の探索。localName は大文字小文字を
/// 区別して比較する(EPUB の XHTML・SVG は小文字の要素名が仕様要件)。
extension XMLElement {
    /// 深さ優先で最初に見つかる、localName が一致する子孫要素。
    func firstDescendant(localName: String) -> XMLElement? {
        for node in children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { return child }
            if let found = child.firstDescendant(localName: localName) { return found }
        }
        return nil
    }

    /// localName が一致する全子孫要素(文書順)。
    func descendants(localName: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for node in children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { result.append(child) }
            result.append(contentsOf: child.descendants(localName: localName))
        }
        return result
    }

    /// SVG の image / a が持つ参照先。xlink 名前空間の href、宣言漏れの素の
    /// `xlink:href`、SVG 2 の素の href の順に引く。
    var xlinkHref: String? {
        attr("href", ns: XMLNamespace.xlink, prefix: "xlink") ?? attr("href")
    }
}

extension XMLElement {
    // cooViewer-oxr.7/89: 本文抽出と JavaScript のテキスト地図が共有する
    // 非表示要素名。表示層は同じ名前一覧だけを複製して DOM を走査する。
    // ReaderScriptContractTests が JS 側の一覧とこの集合の一致を検証する。
    static let readableTextSkippedElementNames =
        alwaysSkippedReadableTextElementNames
            .union(svgSkippedReadableTextElementNames)
            .union(mathMLSkippedReadableTextElementNames)

    static func shouldSkipReadableTextElement(_ element: XMLElement) -> Bool {
        guard let name = element.localName?.lowercased() else { return false }
        if alwaysSkippedReadableTextElementNames.contains(name) { return true }
        var ancestor: XMLNode? = element
        while let node = ancestor {
            if let candidate = node as? XMLElement {
                let ancestorName = candidate.localName?.lowercased()
                if svgSkippedReadableTextElementNames.contains(name),
                   candidate.uri == XMLNamespace.svg || ancestorName == "svg"
                {
                    return true
                }
                if mathMLSkippedReadableTextElementNames.contains(name),
                   candidate.uri == XMLNamespace.mathML
                    || ancestorName == "math"
                {
                    return true
                }
            }
            ancestor = node.parent
        }
        return false
    }

    private static let alwaysSkippedReadableTextElementNames: Set<String> = [
        "rt", "rp", "rtc", "script", "style",
    ]
    private static let svgSkippedReadableTextElementNames: Set<String> = [
        "title", "desc",
    ]
    private static let mathMLSkippedReadableTextElementNames: Set<String> = [
        "annotation", "annotation-xml",
    ]

    /// 名前空間 URI + ローカル名で子要素を探す。名前空間宣言を欠いた不正
    /// ファイルの救済として、URI 一致に加え「接頭辞なし・URI なし」の要素も
    /// 同名なら受け入れる(EPUB 実在ファイルへの寛容さを優先)
    func wsChildren(_ localName: String, ns uri: String) -> [XMLElement] {
        let matched = elements(forLocalName: localName, uri: uri)
        if !matched.isEmpty { return matched }
        return (children ?? []).compactMap { node -> XMLElement? in
            guard let element = node as? XMLElement,
                  element.localName == localName,
                  element.uri == nil || element.uri?.isEmpty == true
            else { return nil }
            return element
        }
    }

    func wsFirst(_ localName: String, ns uri: String) -> XMLElement? {
        wsChildren(localName, ns: uri).first
    }

    /// 属性値(接頭辞なし属性は名前空間を持たないため名前だけで引く)
    func attr(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }

    /// 名前空間付き属性(epub:type 等)。宣言漏れファイルの救済として
    /// 接頭辞付きの素の名前でも引いてみる
    func attr(_ localName: String, ns uri: String, prefix: String) -> String? {
        attribute(forLocalName: localName, uri: uri)?.stringValue
            ?? attribute(forName: "\(prefix):\(localName)")?.stringValue
    }

    /// cooViewer-oxr.7: XML 空白と NBSP の連続だけを畳み、U+3000 は保持する。
    var normalizedText: String {
        Self.collapsingXMLWhitespace(stringValue ?? "")
    }

    /// cooViewer-oxr.7/89: ルビ読み・非表示テキストを除いた目次用文字列。
    /// SVG と MathML の代替説明は名前空間または祖先要素を見て除外する。
    var readableText: String {
        func collect(
            from element: XMLElement,
            insideSVG: Bool,
            insideMathML: Bool
        ) -> String {
            let name = element.localName?.lowercased() ?? ""
            let isSVG = insideSVG || element.uri == XMLNamespace.svg || name == "svg"
            let isMathML = insideMathML
                || element.uri == XMLNamespace.mathML
                || name == "math"
            if Self.alwaysSkippedReadableTextElementNames.contains(name)
                || (isSVG && Self.svgSkippedReadableTextElementNames.contains(name))
                || (isMathML
                    && Self.mathMLSkippedReadableTextElementNames.contains(name))
            {
                return ""
            }
            return (element.children ?? []).map { node in
                if let child = node as? XMLElement {
                    return collect(
                        from: child, insideSVG: isSVG, insideMathML: isMathML)
                }
                return node.kind == .text ? (node.stringValue ?? "") : ""
            }.joined()
        }

        let text = Self.collapsingXMLWhitespace(
            collect(from: self, insideSVG: false, insideMathML: false))
        if !text.isEmpty { return text }

        // cooViewer-oxr.7: W3C RS 3.4 §8 に従い画像代替文を優先する。
        if let image = Self.firstDescendantImage(in: self) {
            for value in [image.attr("alt"), image.attr("title")].compactMap({ $0 }) {
                let fallback = Self.collapsingXMLWhitespace(value)
                if !fallback.isEmpty { return fallback }
            }
        }
        for value in [attr("aria-label"), attr("title")].compactMap({ $0 }) {
            let fallback = Self.collapsingXMLWhitespace(value)
            if !fallback.isEmpty { return fallback }
        }
        return ""
    }

    private static func firstDescendantImage(in element: XMLElement) -> XMLElement? {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName?.lowercased() == "img" { return child }
            if let image = firstDescendantImage(in: child) { return image }
        }
        return nil
    }

    private static func collapsingXMLWhitespace(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var pendingSpace = false
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x0009, 0x000A, 0x000D, 0x0020, 0x00A0:
                if !result.isEmpty { pendingSpace = true }
            default:
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // cooViewer-oxr.6/7: 画像ページ判定専用。非本文の要素と非表示の代替文を
    // 除く。Core では外部 CSS は評価しない。
    var normalizedVisibleText: String {
        func text(in element: XMLElement, insideSVG: Bool) -> String {
            let name = element.localName?.lowercased() ?? ""
            let isSVG = insideSVG || name == "svg"
            if name == "script" || name == "style"
                || (isSVG && (name == "title" || name == "desc"))
                || element.attribute(forName: "hidden") != nil {
                return ""
            }
            // cooViewer-oxr.6: インラインの display:none も WebKit 側と揃える。
            if let style = element.attr("style"),
               style.range(of: #"(?:^|;)\s*display\s*:\s*none\s*(?:!important\s*)?(?:;|$)"#,
                           options: [.regularExpression, .caseInsensitive]) != nil {
                return ""
            }
            return (element.children ?? []).map { node in
                if let child = node as? XMLElement {
                    return text(in: child, insideSVG: isSVG)
                }
                return node.kind == .text ? (node.stringValue ?? "") : ""
            }.joined()
        }
        return text(in: self, insideSVG: false)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
