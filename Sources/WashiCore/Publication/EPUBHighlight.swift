import Foundation

/// spine 項目から抽出した本文の範囲に錨づけした、保存できるハイライト
/// (メモも付けられる)。
///
/// A saved highlight (optionally with a note) anchored to a range of the
/// spine item's extracted plain text.
///
/// 錨は `EPUBSearchHit.utf16Range` が使い、
/// `EPUBReaderView.go(to:textRange:)` が解決するのと同じ UTF-16 範囲。
/// 進行率で表した位置とは異なり、文字サイズ・ビューポート・テーマを変えても
/// ずれない。ホストが自身の保存形式と対応付けやすいよう、データ構造は意図的に
/// Readium の annotation に近づけている(cooViewer-oxr.46 C40)。
///
/// The anchor is the same UTF-16 range that `EPUBSearchHit.utf16Range` uses and
/// that `EPUBReaderView.go(to:textRange:)` resolves, so it survives font-size,
/// viewport and theme changes — unlike a position expressed as a progression.
/// The shape is deliberately close to a Readium annotation so a host can map
/// its own store onto it (cooViewer-oxr.46 C40).
public struct EPUBHighlight: Sendable, Codable, Equatable, Identifiable {
    /// 見た目のスタイル。リーダーは CSS Custom Highlight API で描画するため、
    /// 本の DOM を変更しない。
    ///
    /// Visual treatment. The reader draws these with the CSS Custom Highlight
    /// API, so they never modify the book's DOM.
    public enum Style: String, Sendable, Codable, CaseIterable {
        case yellow, green, blue, pink, underline
    }

    /// ホストが決める安定した識別子(UUID 文字列でよい)。
    ///
    /// Stable identity, chosen by the host (a UUID string works well).
    public var id: String
    /// 範囲が属する項目の、読む順序でのインデックス。
    ///
    /// Reading-order index of the item the range belongs to.
    public var spineIndex: Int
    /// その項目の idref。`EPUBLocator.idref` と同様に、本が改訂されても
    /// ハイライトを追跡できるようにする。
    ///
    /// The idref of that item, so the highlight survives a revised edition
    /// the same way `EPUBLocator.idref` does.
    public var idref: String?
    /// 項目から抽出した本文内のオフセット(UTF-16 コード単位)。
    ///
    /// Offset, in UTF-16 code units of the item's extracted text.
    public var utf16Offset: Int
    /// UTF-16 コード単位での長さ。常に 1 以上。
    ///
    /// Length in UTF-16 code units. Always at least 1.
    public var utf16Length: Int
    public var style: Style
    /// 読者が付けたメモ(ある場合のみ)。Washi は内容を変えずに保存・返却する。
    ///
    /// The reader's own note, if any. Washi stores and returns it untouched.
    public var note: String?

    public init(id: String, spineIndex: Int, idref: String? = nil,
                utf16Offset: Int, utf16Length: Int,
                style: Style = .yellow, note: String? = nil) {
        self.id = id
        self.spineIndex = spineIndex
        self.idref = idref
        self.utf16Offset = max(0, utf16Offset)
        self.utf16Length = max(1, utf16Length)
        self.style = style
        self.note = note
    }

    /// 錨づけした範囲を、`go(to:textRange:)` が受け取る形式で返す。
    ///
    /// The anchored range, in the form `go(to:textRange:)` takes.
    public var textRange: (utf16Offset: Int, utf16Length: Int) {
        (utf16Offset, utf16Length)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        spineIndex = try values.decode(Int.self, forKey: .spineIndex)
        idref = try values.decodeIfPresent(String.self, forKey: .idref)
        // 保存データの異常値を持ち込ませない(EPUBLocator と同じ方針)
        utf16Offset = max(0, try values.decode(Int.self, forKey: .utf16Offset))
        utf16Length = max(1, try values.decode(Int.self, forKey: .utf16Length))
        style = (try? values.decode(Style.self, forKey: .style)) ?? .yellow
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }
}
