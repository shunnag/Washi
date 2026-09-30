import Foundation

/// href の `#` から後(フラグメント)と手前(文書部分)の切り出し。リーダーの
/// 内部リンク・目次と、メディアオーバーレイの par の text が同じ規則で扱う。
/// WashiCore の公開 API は増やさず、表示層の内部だけで使う。
extension ContainerPath {
    /// href からフラグメントを取り出す。`#` が無いか `#` の後が空なら nil。
    /// split は空要素を落とすため "#note1" のような同一文書内リンクで
    /// 壊れないよう firstIndex で切る。
    /// cooViewer-oxr.32: DOM id は URI fragment の percent decode 後の値で
    /// 照合する。不正な escape は実在本を壊さないよう原文へ fallback する。
    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let encoded = String(href[href.index(after: hash)...])
        guard !encoded.isEmpty else { return nil }
        return encoded.removingPercentEncoding ?? encoded
    }

    /// href の `#` より手前。同一文書内リンク("#id")なら空文字列。
    static func documentPart(of href: String) -> String {
        guard let hash = href.firstIndex(of: "#") else { return href }
        return String(href[..<hash])
    }
}
