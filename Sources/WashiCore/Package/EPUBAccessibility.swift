import Foundation

/// 出版物のアクセシビリティメタデータ(schema.org の a11y 語彙と
/// EPUB Accessibility への適合情報)を、型付きの値として公開する。
///
/// The accessibility metadata of a publication (schema.org a11y vocabulary and
/// EPUB Accessibility conformance), surfaced as typed values.
///
/// 閲覧システムには、こうした情報の表示が求められる機会が増えている
/// (EU のアクセシビリティ法など)。本に宣言がなければ全フィールドは空になる。
/// アクセシビリティ欄を表示するかどうかは ``isEmpty`` で判断できる。
///
/// Reading systems increasingly must display this (e.g. the EU Accessibility
/// Act). All fields default to empty when a book declares nothing; check
/// ``isEmpty`` to decide whether to show an accessibility section at all.
public struct EPUBAccessibility: Sendable, Equatable {
    /// `schema:accessMode` — コンテンツを受け取る際に使う感覚の種類
    /// (例: "textual"、"visual"、"auditory")。
    ///
    /// `schema:accessMode` — the human sensory modes the content is in
    /// (e.g. "textual", "visual", "auditory").
    public let accessModes: [String]
    /// `schema:accessModeSufficient` — 内側の各配列は、出版物全体を利用するのに
    /// 十分なアクセスモードの組み合わせを表す。
    ///
    /// `schema:accessModeSufficient` — each inner array is one set of access
    /// modes sufficient to consume the whole publication.
    public let accessModesSufficient: [[String]]
    /// `schema:accessibilityFeature` — アクセシビリティを支援する機能
    /// (例: "structuralNavigation"、"alternativeText"、"displayTransformability")。
    ///
    /// `schema:accessibilityFeature` — features that aid access
    /// (e.g. "structuralNavigation", "alternativeText", "displayTransformability").
    public let features: [String]
    /// `schema:accessibilityHazard` — 既知の危険性
    /// (例: "flashing"、"noFlashingHazard"、"motionSimulation")。
    ///
    /// `schema:accessibilityHazard` — known hazards
    /// (e.g. "flashing", "noFlashingHazard", "motionSimulation").
    public let hazards: [String]
    /// `schema:accessibilitySummary` — 人が読める要約。提供されている場合のみ。
    ///
    /// `schema:accessibilitySummary` — a human-readable summary, if provided.
    public let summary: String?
    /// `dcterms:conformsTo` — パッケージメタデータの `meta` または `link` で
    /// 宣言された EPUB Accessibility の適合先 URL。宣言がある場合のみ。
    ///
    /// `dcterms:conformsTo` — EPUB Accessibility conformance URLs, if any,
    /// declared through either `meta` or `link` package metadata.
    public let conformsTo: [String]
    /// `a11y:certifiedBy` — 適合の表明を認証した主体。
    ///
    /// `a11y:certifiedBy` — the party that certified the conformance claim.
    public let certifiedBy: [String]
    /// `a11y:certifierCredential` — 認証者が保有する資格情報へのリンク。
    ///
    /// `a11y:certifierCredential` — links to credentials held by the certifier.
    public let certifierCredentials: [String]

    /// 本がアクセシビリティメタデータをまったく宣言していなければ true。
    ///
    /// True when the book declares no accessibility metadata at all.
    public var isEmpty: Bool {
        accessModes.isEmpty && accessModesSufficient.isEmpty && features.isEmpty
            && hazards.isEmpty && summary == nil && conformsTo.isEmpty
            && certifiedBy.isEmpty && certifierCredentials.isEmpty
    }
}

extension EPUBMetadata {
    /// メディアオーバーレイの再生中、読み上げているテキストに閲覧システムが
    /// 適用する CSS クラス(`media:active-class`)。宣言されている場合のみ。
    /// 宣言値が空、または単一の CSS トークンでない場合(途中に空白があるなど)は
    /// nil を返し、呼び出し側が有効な既定値へフォールバックできるようにする。
    /// こうした値を `classList.add` へ渡すと例外が発生し、読み上げ中のページ追従が
    /// 気付かれないまま壊れるため。
    ///
    /// The CSS class a reading system applies to the text currently being read
    /// during media-overlay playback (`media:active-class`), if declared.
    /// Returns nil when the declared value is empty or not a single CSS token
    /// (e.g. contains internal whitespace), so the caller falls back to a valid
    /// default — passing such a value to `classList.add` throws and would
    /// silently break page-following during narration.
    public var mediaOverlayActiveClass: String? {
        guard let value = metaItems.first(where: {
            $0.refines == nil && $0.property == "media:active-class"
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        return value
    }

    /// 文書の schema.org / EPUB-a11y の meta プロパティとアクセシビリティ関連の
    /// リンクを集約した、出版物のアクセシビリティメタデータ。
    ///
    /// The publication's accessibility metadata, assembled from the document's
    /// schema.org / EPUB-a11y meta properties and accessibility links.
    public var accessibility: EPUBAccessibility {
        // 文書全体の meta(refines == nil)だけを対象にする
        func values(_ property: String) -> [String] {
            metaItems
                .filter { $0.refines == nil && $0.property == property }
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        // accessModeSufficient は 1 つの meta 値がカンマ区切りの「十分な集合」
        let sufficient = values("schema:accessModeSufficient").map { line in
            line.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.filter { !$0.isEmpty }
        return EPUBAccessibility(
            accessModes: values("schema:accessMode"),
            accessModesSufficient: sufficient,
            features: values("schema:accessibilityFeature"),
            hazards: values("schema:accessibilityHazard"),
            summary: values("schema:accessibilitySummary").first,
            conformsTo: values("dcterms:conformsTo")
                + accessibilityConformanceLinks,
            certifiedBy: values("a11y:certifiedBy"),
            certifierCredentials: values("a11y:certifierCredential")
                + accessibilityCertifierCredentialLinks)
    }

    /// 主な著者。MARC の役割が `aut` の作成者を選び、該当者がいなければ
    /// 全作成者を使う。`display-seq` にかかわらず文書順とし、
    /// file-as ではなく表示名を返す。
    ///
    /// The primary authors — creators whose MARC role is `aut`, or all creators
    /// when none has that role. Uses document order regardless of
    /// `display-seq`, returning display names (not file-as).
    public var authors: [String] {
        let authored = creators.filter { $0.role == "aut" }
        let chosen = authored.isEmpty ? creators : authored
        return chosen.map(\.value)
    }

    /// この出版物が属するシリーズ(コレクション)。種別が `series` のものを
    /// 優先し、なければ最初に宣言されたコレクションを使う。何もなければ nil。
    ///
    /// The series (collection) this publication belongs to, preferring one
    /// typed `series`, else the first declared collection. Nil if none.
    public var series: EPUBCollectionMembership? {
        collections.first { $0.type == "series" } ?? collections.first
    }
}
