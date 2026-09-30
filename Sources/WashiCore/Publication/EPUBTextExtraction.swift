import Foundation

extension EPUBPublication {
    /// spine の 1 項目から、読める本文をプレーンテキストとして抽出する。
    ///
    /// Extracts the readable plain text of one spine item.
    ///
    /// XHTML の body をテキストへ平坦化する。区切りを表す要素境界(段落・見出し・
    /// リスト項目・`<br>`)は改行に変え、`<script>`/`<style>` の内容は除く。
    /// ルビの注釈テキスト(`<rt>`、`<rp>`)も除き、親文字が途切れず読めるようにする。
    /// これは読者が検索する本文でもある。連続する空白は畳み込む。
    ///
    /// The XHTML body is flattened to text: element boundaries that imply a
    /// break (paragraphs, headings, list items, `<br>`) become newlines,
    /// `<script>`/`<style>` content is dropped, and ruby annotation text
    /// (`<rt>`, `<rp>`) is removed so the base text reads continuously — which
    /// is also what a reader searches for. Runs of whitespace are collapsed.
    ///
    /// - Parameter index: spine 項目の、読む順序でのインデックス。
    ///   reading-order index of the spine item.
    /// - Returns: 項目の本文。読める body がなければ空文字列(画像だけのページなど)。
    ///   the item's plain text, or an empty string if it has no
    ///   readable body (e.g. an image-only page).
    /// - Throws: 項目を読み取れない場合は ``EPUBError``。
    ///   ``EPUBError`` if the item cannot be read.
    public func extractText(forSpineIndex index: Int) throws -> String {
        guard readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        return try cachedExtractedText(forSpineIndex: index) {
            let entry = readingOrder[index]
            let mediaType = EPUBMediaType.normalized(entry.resolvedItem.mediaType)
            // cooViewer-oxr.10: 非 XML spine は解析せず空本文として扱う。
            guard Self.textExtractableMediaTypes.contains(mediaType) else {
                return ""
            }
            // cooViewer-oxr.16: 本文も spine 宣言元ではなく描画用 fallback から得る。
            let (data, _) = try resource(at: entry.resolvedContainerPath)
            guard let document = try? WashiXML.document(from: data),
                  let root = document.rootElement() else { return "" }
            let body = root.firstDescendant(localName: "body") ?? root
            var text = ""
            Self.appendPlainText(of: body, into: &text)
            return Self.collapsingWhitespace(text)
        }
    }

    /// 抽出した本文の長さから、各 spine 項目のページ数を WebKit なしで高速に
    /// 概算する。画面外での正確な census が終わる前に、「約 N ページ」をすぐ
    /// 表示したいときに使える。本文がない画像だけのページは 1 ページと数える。
    ///
    /// A fast, WebKit-free estimate of each spine item's page count, based on
    /// extracted text length. Useful to show an approximate "~N pages" instantly
    /// before the exact offscreen census completes. Image-only pages (no body
    /// text) count as one page.
    ///
    /// - Parameter charactersPerPage: リフロー後の 1 ページ当たりの想定文字数。
    ///   現在のフォントとビューポートで実際に census を行い、総文字数 ÷ 実測
    ///   ページ数で補正すると概算の精度が上がる。既定値は一般的な本文フォントを
    ///   読みやすい幅で表示する場合に合う。
    ///   assumed characters per reflowed page.
    ///   Calibrate it from a real census (total characters ÷ measured pages) for
    ///   the current font and viewport to sharpen the estimate; the default
    ///   suits a typical body font at a comfortable reading width.
    public func estimatedPageCounts(charactersPerPage: Int = 1200) -> [Int] {
        let perPage = Double(max(1, charactersPerPage))
        return readingOrder.indices.map { index in
            let chars = (try? extractText(forSpineIndex: index))?.count ?? 0
            return max(1, Int((Double(chars) / perPage).rounded(.up)))
        }
    }

    /// 本全体のページ数を WebKit なしで高速に概算する。
    /// ``estimatedPageCounts(charactersPerPage:)`` を参照。
    ///
    /// A fast, WebKit-free estimate of the whole book's page count.
    /// See ``estimatedPageCounts(charactersPerPage:)``.
    public func estimatedPageCount(charactersPerPage: Int = 1200) -> Int {
        estimatedPageCounts(charactersPerPage: charactersPerPage).reduce(0, +)
    }

    // MARK: - 実装(内部コメントは日本語)

    /// cooViewer-oxr.89/92: 要素配下のテキストを不可視要素と改行境界を
    /// 尊重しつつ連結する。
    private static func appendPlainText(of element: XMLElement,
                                        into text: inout String) {
        for node in element.children ?? [] {
            switch node.kind {
            case .text:
                text += node.stringValue ?? ""
            case .element:
                guard let child = node as? XMLElement,
                      let name = child.localName else { continue }
                if XMLElement.shouldSkipReadableTextElement(child) { continue }
                // 改行の有無は UTF-16/UTF-8 のコード単位で見る(cooViewer-0ig):
                // Character の hasSuffix("\n") は末尾が "\r\n"(1 書記素)のとき偽になり、
                // JS 側の UTF-16 単位の地図と改行数がずれる
                let normalizedName = name.lowercased()
                if plainTextBreakingElementNames.contains(normalizedName),
                   text.utf8.last != UInt8(ascii: "\n") {
                    text += "\n"
                }
                appendPlainText(of: child, into: &text)
                if plainTextBreakingElementNames.contains(normalizedName),
                   text.utf8.last != UInt8(ascii: "\n") {
                    text += "\n"
                }
            default:
                continue
            }
        }
    }

    /// 連続する空白を 1 つに畳み、行頭行末の空白を除く(改行は段落境界として
    /// 残すが、3 つ以上連続する改行は 2 つへ丸める)
    static func collapsingWhitespace(_ text: String) -> String {
        var lines: [String] = []
        // コード単位の "\n" で分割する(Character の split は "\r\n" を割らない。cooViewer-0ig)
        for rawLine in text.components(separatedBy: "\n") {
            let collapsed = rawLine
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            lines.append(collapsed)
        }
        // 空行の連続を 1 つへ
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty == true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // cooViewer-oxr.10: 再帰ごとの Set 再構築を避ける。
    private static let plainTextBreakingElementNames: Set<String> = [
        "p", "div", "br", "li", "tr", "td", "th", "caption", "section",
        "article", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6",
        "figure", "figcaption", "table", "ul", "ol", "dl", "dd", "dt",
        "hr", "pre",
    ]

    // cooViewer-oxr.10: spine の本文解析対象を EPUB 内容文書へ限定する。
    private static let textExtractableMediaTypes: Set<String> = [
        "application/xhtml+xml", "text/html", "image/svg+xml",
    ]

}
