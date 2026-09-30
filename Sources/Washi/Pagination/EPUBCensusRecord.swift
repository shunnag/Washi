import Foundation

/// 保存できる本全体のページ割り census(特定の表示メトリクスに対する
/// spine 項目ごとのページ数)。``EPUBReaderView/exportCensus()`` で
/// 書き出し、次回開くときに ``EPUBReaderView/importCensus(_:)`` で
/// 再注入すれば、画面外での再実測を省ける。Codable に準拠し、ホストが
/// 本の状態と一緒に保存できる。
///
/// A persisted whole-book pagination census (per-spine-item page counts for a
/// specific set of display metrics). Export it with
/// ``EPUBReaderView/exportCensus()`` and re-inject it with
/// ``EPUBReaderView/importCensus(_:)`` on a later open to skip the offscreen
/// re-measure. Codable so a host can store it alongside its book state.
public struct EPUBCensusRecord: Sendable, Codable, Equatable {
    /// ページ数を実測した表示メトリクスのキー(フォント倍率、ビューポート、
    /// 余白、見開きなど)。現在のメトリクスが一致するときだけ再利用する。
    ///
    /// The display-metrics key the counts were measured for (font scale,
    /// viewport, margins, spread, …). Only reused when the current metrics match.
    public let metricsKey: String
    /// 読書順に並べた、各 spine 項目のページ数。
    ///
    /// Page count of each spine item, in reading order.
    public let counts: [Int]
    /// 実測時点の本のリリース識別子。異なる版のページ数を排除するために使う。
    /// 一意識別子と `dcterms:modified` が両方あれば組み合わせ、更新日時が
    /// なければ一意識別子だけを使う。一意識別子がない場合に限り nil になる。
    ///
    /// The book's release identifier at measure time, used to reject counts
    /// from a different edition. It combines the unique identifier and
    /// `dcterms:modified` when both exist, falls back to the unique identifier
    /// when the modified date is absent, and is nil only when no unique
    /// identifier is available.
    public let releaseIdentifier: String?

    public init(metricsKey: String, counts: [Int], releaseIdentifier: String?) {
        self.metricsKey = metricsKey
        self.counts = counts
        self.releaseIdentifier = releaseIdentifier
    }

    // Persisted host data can be corrupt even when book and metrics identities
    // match. All page offsets require positive counts and a representable sum.
    var hasValidCounts: Bool {
        var total = 0
        for count in counts {
            guard count > 0 else { return false }
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return false }
            total = sum.partialValue
        }
        return true
    }
}
