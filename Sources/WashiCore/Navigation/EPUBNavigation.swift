import Foundation

/// 目次・ページ一覧・ランドマークの 1 項目(木構造)。
///
/// A single entry in the table of contents, page list, or landmarks (a tree structure).
public struct EPUBNavItem: Sendable, Hashable {
    public let title: String
    /// ``EPUBNavigation/basePath`` を基準に解決する href(フラグメントを含む)。
    /// 通常は記載されたまま保持する。空の HTML ナビゲーション表へ統合する
    /// NCX 項目は、両文書のリンク先を保つためコンテナルートからの相対参照に
    /// 変えることがある。見出しだけの項目(リンクのない span)では nil。
    ///
    /// The href to resolve against ``EPUBNavigation/basePath``, including any
    /// fragment. It is normally preserved as written; NCX entries merged into
    /// an empty HTML navigation table may be made container-root-relative so
    /// both documents' links retain the same targets. Nil for heading-only
    /// entries (a linkless span).
    public let href: String?
    /// ランドマークの epub:type("cover" / "bodymatter" / "toc" など)。
    ///
    /// The landmark's epub:type ("cover" / "bodymatter" / "toc", etc.).
    public let epubType: String?
    public let children: [EPUBNavItem]

    public init(title: String, href: String?, epubType: String? = nil,
                children: [EPUBNavItem] = []) {
        self.title = title
        self.href = href
        self.epubType = epubType
        self.children = children
    }
}

/// ナビゲーションデータ一式。
///
/// A complete set of navigation data.
public struct EPUBNavigation: Sendable {
    public var toc: [EPUBNavItem] = []
    public var pageList: [EPUBNavItem] = []
    public var landmarks: [EPUBNavItem] = []
    /// ナビゲーション文書(または NCX)のコンテナ相対パス。href 解決の基準に使う。
    ///
    /// The container-relative path of the navigation document (or NCX), used as the base for resolving hrefs.
    public var basePath: String = ""
}

/// EPUB 3 ナビゲーション文書(XHTML nav。EPUB 3.3 §7)のパーサ
enum NavigationDocumentParser {
    static func parse(data: Data, at containerPath: String) throws -> EPUBNavigation {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("ナビゲーション文書が壊れている: \(containerPath)")
        }
        var navigation = EPUBNavigation()
        navigation.basePath = containerPath

        let navElements = collectNavElements(root)
        for nav in navElements {
            let types = (nav.attr("type", ns: XMLNamespace.epubOps, prefix: "epub") ?? "")
                .components(separatedBy: .whitespaces)
            let items = parseList(nav)
            if types.contains("toc") {
                navigation.toc = items
            } else if types.contains("page-list") {
                navigation.pageList = items
            } else if types.contains("landmarks") {
                navigation.landmarks = items
            } else if navigation.toc.isEmpty {
                // epub:type を欠く不正ファイルの救済: 最初の nav を目次とみなす
                navigation.toc = items
            }
        }
        return navigation
    }

    private static func collectNavElements(_ element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        if element.localName == "nav" { result.append(element) }
        for node in element.children ?? [] {
            if let child = node as? XMLElement {
                result.append(contentsOf: collectNavElements(child))
            }
        }
        return result
    }

    /// nav 直下の ol(なければ子孫最初の ol)を木として読む
    private static func parseList(_ nav: XMLElement) -> [EPUBNavItem] {
        guard let list = firstDescendant("ol", in: nav) else { return [] }
        return parseListItems(list)
    }

    private static func parseListItems(_ list: XMLElement) -> [EPUBNavItem] {
        var items: [EPUBNavItem] = []
        for node in list.children ?? [] {
            guard let li = node as? XMLElement, li.localName == "li" else { continue }
            var children: [EPUBNavItem] = []
            for childNode in li.children ?? [] {
                guard let child = childNode as? XMLElement else { continue }
                if child.localName == "ol" {
                    children = parseListItems(child)
                }
            }

            // cooViewer-oxr.7: 不正な wrapper を許容しつつ、子 ol 内のリンクを
            // 見出しとして拾わない。span より a を常に優先する。
            let anchor = firstLabelDescendant("a", in: li)
            let span = anchor == nil ? firstLabelDescendant("span", in: li) : nil
            let label = anchor ?? span
            let title = label?.readableText ?? ""
            let href = anchor?.attr("href")
            let epubType = anchor?.attr("type", ns: XMLNamespace.epubOps,
                                        prefix: "epub")
            guard !title.isEmpty || href != nil || !children.isEmpty else { continue }
            items.append(EPUBNavItem(title: title, href: href,
                                     epubType: epubType, children: children))
        }
        return items
    }

    /// cooViewer-oxr.7: li のラベル領域を探索し、入れ子の ol は除外する
    private static func firstLabelDescendant(_ localName: String,
                                             in element: XMLElement) -> XMLElement? {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { return child }
            if child.localName == "ol" { continue }
            if let found = firstLabelDescendant(localName, in: child) {
                return found
            }
        }
        return nil
    }

    private static func firstDescendant(_ localName: String,
                                        in element: XMLElement) -> XMLElement? {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { return child }
            if let found = firstDescendant(localName, in: child) { return found }
        }
        return nil
    }
}

/// EPUB 2 互換の NCX(toc.ncx)パーサ。EPUB 3 でも後方互換のため同梱される
/// ことが多く、nav 文書がない場合のフォールバックに使う
enum NCXParser {
    static func parse(data: Data, at containerPath: String) throws -> EPUBNavigation {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("NCX が壊れている: \(containerPath)")
        }
        var navigation = EPUBNavigation()
        navigation.basePath = containerPath
        if let navMap = root.wsFirst("navMap", ns: XMLNamespace.ncx) {
            navigation.toc = parseNavPoints(in: navMap)
        }
        if let pageList = root.wsFirst("pageList", ns: XMLNamespace.ncx) {
            navigation.pageList = pageList
                .wsChildren("pageTarget", ns: XMLNamespace.ncx)
                .compactMap(parsePoint)
        }
        return navigation
    }

    private static func parseNavPoints(in element: XMLElement) -> [EPUBNavItem] {
        element.wsChildren("navPoint", ns: XMLNamespace.ncx).compactMap { point in
            guard let item = parsePoint(point) else { return nil }
            let children = parseNavPoints(in: point)
            return EPUBNavItem(title: item.title, href: item.href,
                               children: children)
        }
    }

    private static func parsePoint(_ point: XMLElement) -> EPUBNavItem? {
        let label = point.wsFirst("navLabel", ns: XMLNamespace.ncx)?
            .wsFirst("text", ns: XMLNamespace.ncx)?.readableText ?? ""
        let src = point.wsFirst("content", ns: XMLNamespace.ncx)?.attr("src")
        guard !label.isEmpty || src != nil else { return nil }
        return EPUBNavItem(title: label, href: src)
    }
}

/// 階層の深さを付けて平坦化した目次の 1 項目。
///
/// One entry of a depth-flattened table of contents.
public struct EPUBFlatTOCEntry: Sendable, Hashable {
    public let title: String
    /// ナビゲーション文書からの相対 href(フラグメントを含む)。
    /// 見出しだけの項目では nil。
    ///
    /// The href relative to the navigation document (with any fragment), or nil
    /// for a heading-only entry.
    public let href: String?
    /// 入れ子の深さ。最上位の項目は 0。
    ///
    /// Nesting depth, 0 for a top-level entry.
    public let depth: Int

    public init(title: String, href: String?, depth: Int) {
        self.title = title
        self.href = href
        self.depth = depth
    }
}

extension EPUBNavItem {
    /// この部分木を深さ優先で平坦化し、各項目に深さを付けた一覧。
    ///
    /// This subtree flattened to a depth-first list with depth levels.
    public func flattened(startingAt depth: Int = 0) -> [EPUBFlatTOCEntry] {
        var result = [EPUBFlatTOCEntry(title: title, href: href, depth: depth)]
        for child in children {
            result.append(contentsOf: child.flattened(startingAt: depth + 1))
        }
        return result
    }
}

extension EPUBNavigation {
    /// 目次を深さ優先で平坦化し、各項目に深さを付けた一覧。木をたどる代わりに
    /// 平坦なアウトラインを描画するホスト向け。
    ///
    /// The table of contents flattened to a depth-first list with depth levels,
    /// for hosts that render a flat outline instead of walking the tree.
    public var flattenedTOC: [EPUBFlatTOCEntry] {
        toc.flatMap { $0.flattened() }
    }
}
