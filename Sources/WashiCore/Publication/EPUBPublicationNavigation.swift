import Foundation

// cooViewer-oxr.8: 目次は文書順を保ったまま一度だけ spine 位置へ写像する。
struct IndexedTOCEntry: Sendable {
    let spineIndex: Int
    let depth: Int
    let title: String
}

extension EPUBPublication {
    // MARK: - 読書位置の突き合わせ

    /// spine index とともに idref を記録した locator を作る。位置の保存には
    /// これを使う。
    ///
    /// Builds a locator with the idref recorded alongside the spine index; use this for persisting a position.
    public func locator(forSpineIndex index: Int,
                        progression: Double = 0) -> EPUBLocator {
        EPUBLocator(spineIndex: index, progression: progression,
                    idref: readingOrder.indices.contains(index)
                        ? readingOrder[index].itemRef.idref : nil)
    }

    /// 保存した位置をこの本と照合する。idref があれば、本の改訂による spine の
    /// 並べ替えや項目の追加・削除を追跡して、正しい項目へ対応付ける。
    /// その idref がなくなっていれば nil を返す(「先頭から始める」などの判断は
    /// 呼び出し側に委ねる)。idref のない旧形式の位置は、範囲内に収めるだけ。
    ///
    /// Matches a saved position against this book. When an idref is present it
    /// tracks spine reordering and additions/removals (a revised edition of the
    /// book) to map onto the correct item, returning nil if that idref is gone
    /// (leaving the caller to decide, e.g. "start from the beginning").
    /// Legacy positions without an idref are only clamped into range.
    public func resolve(_ locator: EPUBLocator) -> EPUBLocator? {
        guard !readingOrder.isEmpty else { return nil }
        if let idref = locator.idref {
            if readingOrder.indices.contains(locator.spineIndex),
               readingOrder[locator.spineIndex].itemRef.idref == idref {
                return locator
            }
            guard let entry = readingOrder.first(
                where: { $0.itemRef.idref == idref }) else { return nil }
            return EPUBLocator(spineIndex: entry.spineIndex,
                               progression: locator.progression, idref: idref)
        }
        let clamped = max(0, min(locator.spineIndex, readingOrder.count - 1))
        return EPUBLocator(spineIndex: clamped, progression: locator.progression)
    }

    // MARK: - href と目次の解決

    /// ナビゲーション項目の href を、読む順序での spine index へ解決する。
    ///
    /// Resolves a navigation item's href into a reading-order spine index.
    public func spineIndex(forNavItem item: EPUBNavItem) -> Int? {
        guard let href = item.href else { return nil }
        return spineIndex(forHref: href)
    }

    /// ナビゲーション文書に記載された href(フラグメントがあってもよい)を、
    /// 読む順序での spine index へ解決する。フラグメントは無視し、リンク先を含む
    /// spine 項目を返す。該当する spine 項目がなければ nil。目次や相互参照からの
    /// 移動に使える。
    ///
    /// Resolves an href (as written in the navigation document, with an optional
    /// fragment) into a reading-order spine index. The fragment is ignored — the
    /// result is the spine item that contains the target. Nil if it resolves to
    /// no spine item. Useful for navigating from a TOC or a cross-reference.
    public func spineIndex(forHref href: String) -> Int? {
        let withoutFragment = href.split(separator: "#", maxSplits: 1,
                                         omittingEmptySubsequences: false)[0]
        let bases = tocBasePath == navigation.basePath
            ? [tocBasePath] : [tocBasePath, navigation.basePath]
        // cooViewer-oxr.9: NCX の toc と nav の補助一覧を併用する場合は、
        // それぞれの基準パスを定数個だけ試す。
        for basePath in bases {
            if let path = ContainerPath.resolve(
                base: basePath, href: String(withoutFragment)),
               let index = spineIndexByContainerPath[path] {
                return index
            }
        }
        return nil
    }

    /// コンテナ内パスから、読む順序でのインデックスを得る(spine にないパスは nil)。
    ///
    /// Container path → reading-order index (nil when the path is not in the spine).
    public func spineIndex(forContainerPath path: String) -> Int? {
        spineIndexByContainerPath[ContainerPath.sanitize(path)]
    }

    /// 指定した spine index が属する章のタイトル。
    ///
    /// The chapter title a spine index belongs to.
    ///
    /// 複数の目次項目が同じ spine 項目を指す場合は、文書順で最初のものを使う。
    /// 項目内のフラグメント位置は考慮しない。柱の表示用で、該当がなければ nil。
    ///
    /// The first table-of-contents entry in document order wins when multiple
    /// entries target the same spine item. Fragment positions inside an item
    /// are not considered. For running-head display; nil when there is no match.
    public func chapterTitle(forSpineIndex index: Int) -> String? {
        var bestSpineIndex = -1
        var title: String?
        for entry in indexedTOC
        where entry.spineIndex <= index && !entry.title.isEmpty {
            // cooViewer-oxr.8: 同じ spine の後続項目では上書きせず文書順先頭を保つ。
            if entry.spineIndex > bestSpineIndex {
                bestSpineIndex = entry.spineIndex
                title = entry.title
            }
        }
        return title
    }

    /// cooViewer-oxr.8: 深さ優先の文書順を崩さず、href を O(1) の索引で写像する。
    static func indexTOC(
        _ items: [EPUBNavItem], basePath: String,
        spineIndexByContainerPath: [String: Int], depth: Int = 0
    ) -> [IndexedTOCEntry] {
        var result: [IndexedTOCEntry] = []
        for item in items {
            if let href = item.href,
               let path = ContainerPath.resolve(base: basePath, href: href),
               let spineIndex = spineIndexByContainerPath[path] {
                result.append(IndexedTOCEntry(
                    spineIndex: spineIndex, depth: depth, title: item.title))
            }
            result.append(contentsOf: indexTOC(
                item.children, basePath: basePath,
                spineIndexByContainerPath: spineIndexByContainerPath,
                depth: depth + 1))
        }
        return result
    }

    /// cooViewer-oxr.9: 別文書から併合する href をコンテナルート相対へ写す。
    static func rootRelativeNavigationItems(
        _ items: [EPUBNavItem], sourceBasePath: String
    ) -> [EPUBNavItem] {
        items.map { item in
            let href = item.href.map { rawHref -> String in
                guard let path = ContainerPath.resolve(
                    base: sourceBasePath, href: rawHref) else { return rawHref }
                let suffixIndex = rawHref.firstIndex { $0 == "?" || $0 == "#" }
                let suffix = suffixIndex.map { String(rawHref[$0...]) } ?? ""
                return "/" + path + suffix
            }
            return EPUBNavItem(
                title: item.title, href: href, epubType: item.epubType,
                children: rootRelativeNavigationItems(
                    item.children, sourceBasePath: sourceBasePath))
        }
    }
}
