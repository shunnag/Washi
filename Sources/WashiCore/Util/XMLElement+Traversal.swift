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
