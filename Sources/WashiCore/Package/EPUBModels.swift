import Foundation

/// 綴じ方向(EPUB 3.3 §5.5、spine の page-progression-direction)。
/// 日本語の縦書きの本は rtl(右綴じ、ページは右 → 左に進む)を使う。
///
/// Page progression direction (EPUB 3.3 §5.5, spine's page-progression-direction).
/// Japanese vertical-writing books use rtl (right-bound; pages advance right → left).
public enum PageProgressionDirection: String, Sendable {
    case ltr
    case rtl
    /// 属性の省略時の値(閲覧システムが言語と組方向から判断してよい)。
    ///
    /// Attribute omitted (the Reading System may decide from language and writing mode).
    case byDefault = "default"
}

/// 出版物が公開する綴じ方向。
///
/// The reading direction exposed by a publication.
///
/// ``PageProgressionDirection`` の API 互換な別名。実効的な綴じ方向は必ず
/// ``PageProgressionDirection/ltr`` または ``PageProgressionDirection/rtl``。
///
/// This is an API-compatible name for ``PageProgressionDirection``. An
/// effective direction is always either ``PageProgressionDirection/ltr`` or
/// ``PageProgressionDirection/rtl``.
public typealias EPUBReadingDirection = PageProgressionDirection

/// 実効的な綴じ方向を決める根拠となった、出版物内の情報を示す。
///
/// Describes which publication signal determined the effective reading direction.
public enum EPUBReadingDirectionSource: Sendable {
    /// パッケージの spine に `page-progression-direction` の宣言がある。
    ///
    /// The package spine declares `page-progression-direction`.
    case declared
    /// パッケージメタデータに Amazon の `primary-writing-mode` の宣言がある。
    ///
    /// Package metadata declares Amazon's `primary-writing-mode` value.
    case primaryWritingModeMeta
    /// 読む順序の冒頭にある文書の CSS が、右から左へ進む縦書きを宣言している。
    ///
    /// CSS used by an early reading-order document declares vertical right-to-left writing.
    case verticalWritingCSS
    /// Dublin Core の主要言語が、通常は右から左へ読む言語。
    ///
    /// The primary Dublin Core language normally reads right-to-left.
    case rtlLanguage
    /// 方向を判断する情報がなかったため、左から右を選んだ。
    ///
    /// No directional signal was present, so left-to-right was selected.
    case fallback
}

/// 人が読むパッケージメタデータの基底テキスト方向。
///
/// Base text direction for human-readable package metadata.
public enum EPUBTextDirection: String, Sendable {
    case ltr
    case rtl
    case auto
}

/// レイアウト方式を表す rendition:layout(EPUB 3.3 §D.3.2)。
///
/// rendition:layout (EPUB 3.3 §D.3.2).
public enum RenditionLayout: String, Sendable {
    case reflowable
    case prePaginated = "pre-paginated"
    /// EPUB 3.4 CR の新しい値。1 つの長い文書を切れ目なくスクロールさせる
    /// 表示(縦スクロール漫画・絵巻)。Washi の描画層は現状これをリフローと
    /// 同じ経路で表示する(cooViewer-oxr.46 C27)。
    ///
    /// A new value in EPUB 3.4 CR for continuously scrolling a single long
    /// document (vertical-scroll comics or picture scrolls). Washi currently
    /// renders this through the same path as reflowable content
    /// (cooViewer-oxr.46 C27).
    case roll
}

/// 画面の向きを表す rendition:orientation。
///
/// rendition:orientation
public enum RenditionOrientation: String, Sendable {
    case auto, landscape, portrait
}

/// 見開きを合成するかを表す rendition:spread。portrait は 3.3 で削除された
/// ため、both として扱う。
///
/// rendition:spread (whether to synthesize spreads; portrait was removed in 3.3 → treated as both).
public enum RenditionSpread: String, Sendable {
    case auto, none, landscape, both
}

/// リフローコンテンツのスクロール方式を表す rendition:flow。
///
/// rendition:flow (scrolling mode for reflowable content).
public enum RenditionFlow: String, Sendable {
    case auto, paginated
    case scrolledContinuous = "scrolled-continuous"
    case scrolledDoc = "scrolled-doc"
}

/// タイトル(title-type による詳細指定を含む)。
///
/// Title (with title-type refine).
public struct EPUBTitle: Sendable, Hashable {
    public let value: String
    /// タイトルの種別: 主題 / 副題 / 短縮形 / コレクション名 / 版 / 拡張形。
    ///
    /// main / subtitle / short / collection / edition / expanded
    public let type: String?
    public let fileAs: String?
    public let displaySeq: Int?
    /// title・metadata・package 要素から継承した、実効的な基底テキスト方向。
    ///
    /// The effective base direction inherited from the title, metadata, or package element.
    public let direction: EPUBTextDirection?
    /// title・metadata・package 要素から継承した、実効的な BCP 47 言語タグ。
    ///
    /// The effective BCP 47 language inherited from the title, metadata, or package element.
    public let language: String?

    /// タイトルを作成する。詳細指定と、言語・テキスト方向の情報も任意に指定できる。
    ///
    /// Creates a title and its optional refinements and language context.
    public init(
        value: String,
        type: String? = nil,
        fileAs: String? = nil,
        displaySeq: Int? = nil,
        direction: EPUBTextDirection? = nil,
        language: String? = nil
    ) {
        self.value = value
        self.type = type
        self.fileAs = fileAs
        self.displaySeq = displaySeq
        self.direction = direction
        self.language = language
    }
}

/// 作成者・寄与者(role による役割の詳細指定を含む)。
///
/// Creator / contributor (with role refine).
public struct EPUBCreator: Sendable, Hashable {
    public let value: String
    /// MARC の役割コード(aut / ill / trl など)。
    ///
    /// MARC relator code (aut / ill / trl, etc.).
    public let role: String?
    public let fileAs: String?
    public let displaySeq: Int?
    /// creator・metadata・package 要素から継承した、実効的な基底テキスト方向。
    ///
    /// The effective base direction inherited from the creator, metadata, or package element.
    public let direction: EPUBTextDirection?
    /// creator・metadata・package 要素から継承した、実効的な BCP 47 言語タグ。
    ///
    /// The effective BCP 47 language inherited from the creator, metadata, or package element.
    public let language: String?

    /// 作成者または寄与者を作成する。メタデータの詳細指定も任意に追加できる。
    ///
    /// Creates a creator or contributor and its optional metadata refinements.
    public init(
        value: String,
        role: String? = nil,
        fileAs: String? = nil,
        displaySeq: Int? = nil,
        direction: EPUBTextDirection? = nil,
        language: String? = nil
    ) {
        self.value = value
        self.role = role
        self.fileAs = fileAs
        self.displaySeq = displaySeq
        self.direction = direction
        self.language = language
    }
}

/// 出版物の識別子を表す dc:identifier。
///
/// dc:identifier
public struct EPUBIdentifier: Sendable, Hashable {
    public let value: String
    public let id: String?
    /// identifier-type または scheme による詳細指定の値。
    ///
    /// Refine value from identifier-type or scheme.
    public let scheme: String?
}

/// 所属コレクションを表す belongs-to-collection(シリーズ情報、EPUB 3.3 §D.4.1)。
///
/// belongs-to-collection (series information; EPUB 3.3 §D.4.1).
public struct EPUBCollectionMembership: Sendable, Hashable {
    public let name: String
    /// collection-type による詳細指定(series / set など)。
    ///
    /// collection-type refine (series / set, etc.).
    public let type: String?
    public let groupPosition: String?
}

/// 汎用の meta 情報(正規化したプロパティ名で保持する)。
///
/// Generic meta (stored under a canonicalized property name).
public struct EPUBMetaItem: Sendable, Hashable {
    /// 既知の語彙は "rendition:layout" のような接頭辞付きの形式へ正規化する。
    ///
    /// Known vocabularies are normalized to a prefixed form such as "rendition:layout".
    public let property: String
    public let value: String
    /// 詳細指定の対象要素の id(# を含まない)。文書全体の meta では nil。
    ///
    /// The id of the element this refines (without #); nil for document-wide meta.
    public let refines: String?
    public let scheme: String?
}

/// rendition プロパティ一式(文書全体の既定値)。
///
/// The full set of rendition properties (document-wide defaults).
public struct RenditionProperties: Sendable {
    public var layout: RenditionLayout = .reflowable
    public var orientation: RenditionOrientation = .auto
    public var spread: RenditionSpread = .auto
    public var flow: RenditionFlow = .auto
    /// 非推奨の rendition:viewport(3.0 時代の名残で、固定レイアウトの既定の
    /// ビューポートを表す)。
    ///
    /// Deprecated rendition:viewport (a relic of 3.0; the default viewport for FXL).
    public var viewport: String?
}

/// パッケージ文書のメタデータ(refines を解決した DCMES)。
///
/// Package document metadata (DCMES with refines resolved).
public struct EPUBMetadata: Sendable {
    /// metadata または package 要素から継承した、実効的な基底テキスト方向。
    ///
    /// The effective base direction inherited from the metadata or package element.
    public let direction: EPUBTextDirection?
    /// metadata または package 要素から継承した、実効的な BCP 47 言語タグ。
    ///
    /// The effective BCP 47 language inherited from the metadata or package element.
    public let language: String?
    public var titles: [EPUBTitle] = []
    public var creators: [EPUBCreator] = []
    public var contributors: [EPUBCreator] = []
    public var publishers: [String] = []
    public var languages: [String] = []
    public var identifiers: [EPUBIdentifier] = []
    /// unique-identifier 属性が参照する dc:identifier の値。
    ///
    /// The value of the dc:identifier referenced by the unique-identifier attribute.
    public var uniqueIdentifier: String?
    /// 更新日時を表す dcterms:modified(元の ISO 8601 文字列のまま保持する)。
    ///
    /// dcterms:modified (kept as the raw ISO 8601 string).
    public var modified: String?
    public var date: String?
    public var description: String?
    public var rights: String?
    /// dc:source — 派生元の資料(底本)。EPUB 3.3 §5.3。
    ///
    /// dc:source — the source material this publication derives from. EPUB 3.3 §5.3.
    public var sources: [String] = []
    /// dc:type — 出版物の種別("dictionary" 等)。
    ///
    /// dc:type — the kind of publication (e.g. "dictionary").
    public var types: [String] = []
    /// dc:relation — 関連資料。
    ///
    /// dc:relation — related resources.
    public var relations: [String] = []
    /// dc:coverage — 対象とする範囲(時代・地域)。
    ///
    /// dc:coverage — the scope covered (time period or region).
    public var coverages: [String] = []
    /// dc:format — 媒体・形式。
    ///
    /// dc:format — the medium or format.
    public var formats: [String] = []
    public var subjects: [String] = []
    public var collections: [EPUBCollectionMembership] = []
    public var rendition = RenditionProperties()
    /// 未解決のものも含む、すべての meta エントリ(拡張用途向け)。
    ///
    /// All meta entries, including unresolved ones (for extension use).
    public var metaItems: [EPUBMetaItem] = []
    // cooViewer-oxr.37: EPUB Accessibility 1.0 の link 形式を、公開する
    // accessibility 値へ統合するまで package 内部で保持する。
    var accessibilityConformanceLinks: [String] = []
    var accessibilityCertifierCredentialLinks: [String] = []

    /// 初期状態が空のメタデータ値を作成する。継承した言語・テキスト方向の情報を
    /// 任意に指定できる。
    ///
    /// Creates an initially empty metadata value with optional inherited language context.
    public init(
        direction: EPUBTextDirection? = nil,
        language: String? = nil
    ) {
        self.direction = direction
        self.language = language
    }

    /// 表示用タイトル(文書順の最初のタイトル。title-type によらない)。
    ///
    /// Display title (the first title in document order, regardless of title-type).
    public var mainTitle: String? {
        titles.first?.value
    }

    /// リリース識別子(unique-identifier + modified、EPUB 3.3 §5.2.3)。
    /// フォント難読化の鍵の導出にも使う一意識別子は、この値ではなく
    /// uniqueIdentifier。
    ///
    /// Release identifier (unique-identifier + modified; EPUB 3.3 §5.2.3).
    /// The unique identifier also used for font-obfuscation key derivation is uniqueIdentifier, not this.
    public var releaseIdentifier: String? {
        guard let uniqueIdentifier else { return nil }
        guard let modified else { return uniqueIdentifier }
        return uniqueIdentifier + "@" + modified
    }
}

/// マニフェストの 1 項目。
///
/// A manifest item.
public struct ManifestItem: Sendable, Hashable {
    public let id: String
    /// パッケージ文書からの相対 href(記載されたまま保持し、コンテナ内パスは
    /// Publication が解決する)。
    ///
    /// href relative to the package document (as written; the in-container path is resolved by Publication).
    public let href: String
    public let mediaType: String
    /// 項目のプロパティ: ナビゲーション / 表紙画像 / スクリプトあり / SVG /
    /// MathML / 外部リソース / switch。
    ///
    /// nav / cover-image / scripted / svg / mathml / remote-resources / switch
    public let properties: Set<String>
    /// フォールバック先の項目 id(コアメディアタイプでない項目向け、EPUB 3.3 §5.6)。
    ///
    /// The fallback item id (for items that are not a core media type; EPUB 3.3 §5.6).
    public let fallback: String?
    /// メディアオーバーレイ(SMIL)の項目 id。
    ///
    /// The item id of the media overlay (SMIL).
    public let mediaOverlay: String?
}

/// spine の 1 項目。
///
/// A single spine item.
public struct SpineItemRef: Sendable, Hashable {
    public let idref: String
    /// linear="no" は補助コンテンツを示す(既定値は true)。
    ///
    /// linear="no" marks auxiliary content (defaults to true).
    public let linear: Bool
    /// page-spread-left / page-spread-right / rendition:page-spread-center や、
    /// 項目ごとの rendition:* の上書き指定など(正規化済み)。
    ///
    /// page-spread-left / page-spread-right / rendition:page-spread-center /
    /// per-item rendition:* overrides, etc. (canonicalized).
    public let properties: Set<String>
    /// 正規化したプロパティを、重複も含めて元の文書順で保持したもの。
    ///
    /// Canonicalized properties in their original document order, including duplicates.
    public let propertyList: [String]
}

/// spine 全体。
///
/// The whole spine.
public struct EPUBSpine: Sendable {
    public let itemRefs: [SpineItemRef]
    public let pageProgressionDirection: PageProgressionDirection
    /// EPUB 2 互換の NCX を指す項目 id(toc 属性)。
    ///
    /// The item id pointing to the EPUB 2-compatible NCX (toc attribute).
    public let tocItemID: String?
}

/// パッケージ文書(OPF)の解析結果。
///
/// The parsed result of the package document (OPF).
public struct EPUBPackage: Sendable {
    /// version 属性("3.0" / "2.0" など、記載されたままの値)。
    ///
    /// version attribute ("3.0" / "2.0", etc., as written).
    public let version: String
    public let metadata: EPUBMetadata
    public let manifest: [ManifestItem]
    public let manifestByID: [String: ManifestItem]
    public let spine: EPUBSpine
    /// パッケージ文書自体のコンテナ内パス(href 解決の基準)。
    ///
    /// The in-container path of the package document itself (the base for href resolution).
    public let path: String

    /// EPUB 3 のナビゲーション文書(properties="nav")。
    ///
    /// The EPUB 3 navigation document (properties="nav").
    public var navItem: ManifestItem? {
        manifest.first { $0.properties.contains("nav") }
    }

    /// 表紙画像(EPUB 3 の properties="cover-image" → EPUB 2 の
    /// meta name="cover" の順に探す)。
    ///
    /// Cover image (EPUB 3 properties="cover-image" → EPUB 2 meta name="cover").
    public var coverImageItem: ManifestItem? {
        if let item = manifest.first(where: { $0.properties.contains("cover-image") }) {
            return item
        }
        // EPUB 2 互換: <meta name="cover" content="item-id">
        if let coverID = metadata.metaItems.first(where: { $0.property == "cover" })?.value {
            return manifestByID[coverID]
        }
        return nil
    }

    /// 文書全体が固定レイアウトかどうか。
    ///
    /// Whether the whole document is fixed-layout.
    public var isFixedLayout: Bool {
        metadata.rendition.layout == .prePaginated
    }

    /// 出版物が 1 本の連続したスクロール表示を求めているか。
    /// `rendition:layout="roll"`(EPUB 3.4)、および `roll` が登場する前に日本の
    /// 出版社が採用していた `pre-paginated` + `scrolled-continuous` の組み合わせで
    /// true になる。EPUB Reading Systems 3.4 では両者を同じように扱うことが
    /// 記されている(cooViewer-oxr.46 C27)。
    ///
    /// Whether the publication asks to be shown as one continuous scroll.
    /// True for `rendition:layout="roll"` (EPUB 3.4) and for the
    /// `pre-paginated` + `scrolled-continuous` combination that Japanese
    /// publishers shipped before `roll` existed; EPUB Reading Systems 3.4
    /// notes the two are to be treated alike (cooViewer-oxr.46 C27).
    public var isScrollLike: Bool {
        if metadata.rendition.layout == .roll { return true }
        return metadata.rendition.layout == .prePaginated
            && metadata.rendition.flow == .scrolledContinuous
    }

    /// spine の 1 項目の実効レイアウト(itemref の rendition:layout-* による
    /// 上書きを反映する)。
    ///
    /// The effective layout for a single spine item (the itemref's rendition:layout-* override).
    public func effectiveLayout(for itemRef: SpineItemRef) -> RenditionLayout {
        // cooViewer-oxr.14: 重複指定は properties(Set) ではなく文書順に
        // 走査し、最初の rendition:layout-* だけを有効にする。
        for property in itemRef.propertyList {
            switch property {
            case "rendition:layout-pre-paginated": return .prePaginated
            case "rendition:layout-reflowable": return .reflowable
            default: continue
            }
        }
        return metadata.rendition.layout
    }

    /// spine の 1 項目の実効的な見開き設定を返す。出版物全体の既定値より、
    /// itemref に最初に現れる上書き指定を優先する。
    ///
    /// Returns the effective spread preference for one spine item, honoring
    /// the first itemref override before the publication-wide default.
    public func effectiveSpread(for itemRef: SpineItemRef) -> RenditionSpread {
        // cooViewer-oxr.51: EPUB 3 の rendition:spread-* と EPUB 2 時代の
        // spread-* の双方を文書順で解決する。
        for property in itemRef.propertyList {
            switch property {
            case "rendition:spread-none", "spread-none": return .none
            case "rendition:spread-landscape", "spread-landscape":
                return .landscape
            case "rendition:spread-both", "spread-both": return .both
            case "rendition:spread-auto", "spread-auto": return .auto
            default: continue
            }
        }
        return metadata.rendition.spread
    }

    /// 実効的な綴じ方向(既定値は言語から推測する。日本語の縦書き文化でも
    /// 仕様上の既定値は ltr で、明示的な rtl の指定がある場合だけ右綴じになる)。
    ///
    /// The effective page progression direction (default is inferred from language: even for
    /// Japanese vertical-writing cultures the spec default is ltr; only an explicit rtl becomes right-bound).
    public var readingDirection: PageProgressionDirection {
        spine.pageProgressionDirection
    }
}
