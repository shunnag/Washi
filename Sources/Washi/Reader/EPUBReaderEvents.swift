import Foundation

/// handlesKeyboardNavigation が false のときにホストへ転送するキーイベント。
///
/// A key event forwarded to the host (when handlesKeyboardNavigation is
/// false).
public struct EPUBKeyEvent: Sendable, Equatable {
    public let key: String
    public let code: String
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    public init(key: String, code: String, shift: Bool = false,
                option: Bool = false, control: Bool = false, command: Bool = false) {
        self.key = key
        self.code = code
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
    }
}

/// ページ面でのクリックの詳細(デリゲートへ転送する)。button は NSEvent と
/// 同じ番号を使う(0 = 左、1 = 右、2 = 中央、3/4 = サイド)。右クリックは通常の
/// `didClick` コールバックには送らず、コンテキストメニューのデリゲート
/// コールバックへ渡すイベントとして表す。
///
/// Details of a click on the page surface (forwarded to the delegate).
/// button uses NSEvent-style numbering (0 = left, 1 = right, 2 = middle,
/// 3/4 = side). Right-clicks are not sent through the regular `didClick`
/// callback; they are represented by the event passed to the context-menu
/// delegate callback instead.
public struct EPUBClickEvent: Sendable, Equatable {
    /// 0..1 に正規化した座標。
    ///
    /// Normalized coordinates in 0..1.
    public let x: Double
    public let y: Double
    /// リーダービューの座標系でのクリック位置。
    ///
    /// Click location in the coordinate system of the reader view.
    public let locationInView: CGPoint
    public let button: Int
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    public init(x: Double, y: Double, locationInView: CGPoint,
                button: Int, shift: Bool, option: Bool,
                control: Bool, command: Bool) {
        self.x = x
        self.y = y
        self.locationInView = locationInView
        self.button = button
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
    }

    /// 修飾キーなしの左クリックか(既定の端タップによるページめくりの対象)。
    ///
    /// Whether this is a left click with no modifier keys (the target of the
    /// default edge-tap page turn).
    public var isPlainPrimary: Bool {
        button == 0 && !shift && !option && !control && !command
    }
}

/// 1 つの spine 項目の、正規化済み UTF-16 テキストマップにおける本文選択。
///
/// A text selection in the normalized UTF-16 text map of one spine item.
public struct EPUBTextSelection: Sendable, Equatable {
    /// 選択範囲を含む spine 項目の、読む順序でのインデックス。
    ///
    /// Reading-order spine index containing the selection.
    public let spineIndex: Int
    /// 選択された正規化済みの本文。
    ///
    /// Selected normalized text.
    public let text: String
    /// 正規化済み本文の選択範囲(UTF-16 コード単位)。
    ///
    /// Selected range in normalized UTF-16 code units.
    public let utf16Range: Range<Int>
    /// リーダービューの座標系で表した、選択範囲の各断片。
    ///
    /// Selection fragments in reader-view coordinates.
    public let rects: [CGRect]

    public init(spineIndex: Int, text: String, utf16Range: Range<Int>,
                rects: [CGRect]) {
        self.spineIndex = spineIndex
        self.text = text
        self.utf16Range = utf16Range
        self.rects = rects
    }
}

/// リフローの spine 項目内にある本文範囲の、正確な移動先。
///
/// The exact landing position of a text range in a reflowable spine item.
public struct EPUBTextRangeLanding: Sendable {
    /// 範囲の先頭を含むページの、0 始まりの番号。
    ///
    /// Zero-based page containing the beginning of the range.
    public let pageInItem: Int
    /// この範囲に対応する、正規化済みの抽出本文の一部(呼び出し元が
    /// 指定した本文)。範囲内の生の DOM テキストではない。
    ///
    /// The normalized extracted-text slice the range represents (what the
    /// caller asked for), not the raw DOM text of the range.
    public let text: String
    /// リーダービューの座標系へ変換した、範囲の各断片。
    ///
    /// Range fragments converted into the reader view's coordinate system.
    public let rects: [CGRect]
}

/// EPUB の読む順序に含まれる文書から、同じ出版物内の別の位置への
/// 解決済みリンク。
///
/// A resolved link from one EPUB reading-order document to another location
/// in the same publication.
public struct EPUBInternalLink: Sendable, Equatable {
    /// 出版物に記載されたとおりの href。
    ///
    /// The href exactly as declared by the publication.
    public let href: String
    /// 現在の文書を基準に解決した、正規化済みのコンテナパス。
    ///
    /// The canonical container path resolved relative to the current document.
    public let containerPath: String
    /// フラグメント識別子がある場合、そのデコード済みの値。
    ///
    /// The decoded fragment identifier, when present.
    public let fragment: String?
    /// リンク先が読む順序に含まれる場合、その出版物内でのインデックス。
    ///
    /// The destination's index in the publication reading order, when present.
    public let targetSpineIndex: Int?
    /// クリックしたアンカーの `epub:type` の値。
    ///
    /// The clicked anchor's `epub:type` value.
    public let epubType: String?
    /// クリックしたアンカーの ARIA ロール。
    ///
    /// The clicked anchor's ARIA role.
    public let role: String?
    /// アンカーが EPUB または ARIA の注への参照か。
    ///
    /// Whether the anchor is an EPUB or ARIA note reference.
    public let isNoteReference: Bool
    /// 同じ文書内にあるリンク先の注に、このアンカーへ戻るリンクが含まれるか。
    ///
    /// Whether a same-document note target contains a link back to the anchor.
    public let hasBacklink: Bool
    /// 同じ文書内のリンク先に `epub:type` がある場合、その値。
    ///
    /// The same-document target's `epub:type` value, when available.
    public let targetEpubType: String?
    /// リーダービューの座標系で表した、クリックしたアンカーの境界矩形。
    ///
    /// The clicked anchor's bounds in the reader view's coordinate system.
    public let anchorRect: CGRect?

    public init(
        href: String,
        containerPath: String,
        fragment: String?,
        targetSpineIndex: Int?,
        epubType: String?,
        role: String?,
        isNoteReference: Bool,
        hasBacklink: Bool,
        targetEpubType: String?,
        anchorRect: CGRect?
    ) {
        self.href = href
        self.containerPath = containerPath
        self.fragment = fragment
        self.targetSpineIndex = targetSpineIndex
        self.epubType = epubType
        self.role = role
        self.isNoteReference = isNoteReference
        self.hasBacklink = hasBacklink
        self.targetEpubType = targetEpubType
        self.anchorRect = anchorRect
    }
}

/// EPUB の注の参照先から抽出した本文と、取得できる場合はそのマークアップ。
///
/// Text and optional markup extracted from an EPUB note target.
public struct EPUBNoteContent: Sendable, Equatable {
    /// 戻りリンクのアンカーを除いた、人が読める形式の注の本文。
    ///
    /// Human-readable note text with backlink anchors removed.
    public let text: String
    /// 現在表示中の文書内の注から、戻りリンクのアンカーを除いた内部 HTML。
    /// 別の文書からは画面表示なしで抽出するため、この値は nil になる。
    ///
    /// Inner HTML with backlink anchors removed for a note in the currently
    /// displayed document. Cross-document extraction is headless and returns
    /// nil here.
    public let html: String?
    /// 注を含む文書の、読む順序でのインデックス。
    ///
    /// Index of the document containing the note in the reading order.
    public let sourceSpineIndex: Int

    public init(text: String, html: String?, sourceSpineIndex: Int) {
        self.text = text
        self.html = html
        self.sourceSpineIndex = sourceSpineIndex
    }
}
