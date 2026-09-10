import Foundation

/// 読書位置(spine 項目 + 項目内の進行率)。リフローレイアウトではウインドウ
/// サイズやフォント設定でページ番号が変わるため、位置を進行率(0..1)で保存する。
///
/// A reading position (spine item + progression within that item). In
/// reflowable layout the page number shifts with window size and font
/// settings, so the position is persisted as a progression ratio (0..1).
public struct EPUBLocator: Sendable, Equatable, Codable {
    public var spineIndex: Int
    /// 項目内の進行率。0.0(先頭)から 1.0(末尾)まで。
    ///
    /// Progression within the item, from 0.0 (start) to 1.0 (end).
    public var progression: Double {
        get { storedProgression }
        set { storedProgression = Self.clampedProgression(newValue) }
    }
    private var storedProgression: Double
    /// spine の itemref の idref。これがあれば、本の改訂で spine の並べ替えや
    /// 項目の追加・削除があっても、正しい項目を追跡できる(EPUBPublication.resolve)。
    /// {spineIndex, progression} だけを保存していた旧形式もデコードできる。
    ///
    /// The idref of the spine itemref. When present, it lets the correct item
    /// be tracked across a revised edition of the book (spine reordering or
    /// added/removed items) (EPUBPublication.resolve). Decode-compatible with
    /// the old saved format (which stored only {spineIndex, progression}).
    public var idref: String?
    /// この位置で最初に見える文字の、項目から抽出した本文内の UTF-16 オフセット。
    /// `progression` だけでは復元時に再量子化され、文字サイズやビューポートを
    /// 変えると保存位置が数ページずれる。錨を使えば同じ文へ戻れる。
    /// 互換性を保つ任意の追加項目で、導入前に保存した locator は nil として
    /// デコードされ、引き続き `progression` を使う(cooViewer-oxr.46 C52)。
    ///
    /// UTF-16 offset, in the item's extracted plain text, of the first character
    /// visible at this position. `progression` alone is re-quantized on restore,
    /// so a saved position drifts by a few pages once the font size or the
    /// viewport changes; the anchor lets the reader land on the same sentence.
    /// Optional and additive: locators saved before this existed decode as nil
    /// and keep using `progression` (cooViewer-oxr.46 C52).
    public var textOffset: Int?

    public init(spineIndex: Int, progression: Double = 0, idref: String? = nil,
                textOffset: Int? = nil) {
        self.spineIndex = spineIndex
        self.storedProgression = Self.clampedProgression(progression)
        self.idref = idref
        self.textOffset = textOffset.flatMap { $0 >= 0 ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case spineIndex
        case progression
        case idref
        case textOffset
    }

    /// 保存済みの locator をデコードし、公開イニシャライザおよびセッターと同じ
    /// 進行率の範囲制限を適用する。
    ///
    /// Decodes a persisted locator while enforcing the same progression bounds
    /// as the public initializer and setter.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        spineIndex = try values.decode(Int.self, forKey: .spineIndex)
        let decoded = try values.decode(Double.self, forKey: .progression)
        // cooViewer-oxr.73: 合成 Codable は init のクランプを通らないため、
        // 永続化データから巨大値や NaN を持ち込ませない。
        storedProgression = Self.clampedProgression(decoded)
        idref = try values.decodeIfPresent(String.self, forKey: .idref)
        // 負値や壊れた保存データはアンカー無しとして扱う(progression へ戻る)
        textOffset = try values.decodeIfPresent(Int.self, forKey: .textOffset)
            .flatMap { $0 >= 0 ? $0 : nil }
    }

    /// locator を安定した公開形式でエンコードする。
    ///
    /// Encodes the stable, public locator representation.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(spineIndex, forKey: .spineIndex)
        try values.encode(storedProgression, forKey: .progression)
        try values.encodeIfPresent(idref, forKey: .idref)
        try values.encodeIfPresent(textOffset, forKey: .textOffset)
    }

    private static func clampedProgression(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }
}
