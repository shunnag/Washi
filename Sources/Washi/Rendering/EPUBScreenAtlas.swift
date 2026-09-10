import AppKit
import Foundation

/// テスト差替用のシーム: 制御可能な fake census を注入できるようにする
/// (実 census は WKWebView を駆動し XCTest では決定論的に動かないため)。
/// 本番は常に `EPUBPaginationCensus` を使う
@MainActor
protocol ScreenPageCensusing {
    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize) async -> [Int]?
    func invalidate()
}

extension EPUBPaginationCensus: ScreenPageCensusing {}

/// テスト差替用のシーム: 派生後メトリクスがサムネイル描画まで
/// 渡ることを WebKit なしで検証する
@MainActor
protocol ScreenThumbnailRendering {
    func thumbnail(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                   contentSize: NSSize, snapshotWidth: CGFloat) async -> CGImage?
    func invalidate()
}

extension EPUBScreenThumbnailRenderer: ScreenThumbnailRendering {}

/// リーダーを開かずに EPUB の画面構成(項目ごとの実測ページ数)と
/// 画面サムネイルを取得する公開窓口。コレクション(複数の本をまとめたもの)の
/// 一覧で、リフロー EPUB を全ページに展開するために使う。
/// census とレンダラはリーダー内部とまったく同じ実装を共有する
/// (EPUBScreenMetrics が唯一の基準)。そのため、後で本を開いたときと
/// ページ割りが一致することを保証する。
///
/// Public facade for obtaining an EPUB's screen plan (measured per-item page
/// counts) and screen thumbnails without opening the reader. Used to fully
/// expand a reflowable EPUB into all of its pages within a collection (merged
/// book) listing.
/// The census and renderer share the exact same implementation used inside the
/// reader (EPUBScreenMetrics is the single source of truth), so the pagination
/// is guaranteed to match what you get when the book is later opened.
@MainActor
public final class EPUBScreenAtlas {
    public let publication: EPUBPublication
    private let census: any ScreenPageCensusing
    private var renderer: (any ScreenThumbnailRendering)?
    /// メトリクスキー → 項目別ページ数
    private var countsCache: [String: [Int]] = [:]
    /// 大きな CSS を含むキーの蓄積を防ぐ。小さな上限なので挿入順で追い出す。
    private static let countsCacheLimit = 16
    private var countsCacheKeys: [String] = []
    /// 実測中の合流(同一メトリクスの並行要求で census を二重に走らせない)
    private var measuring: [String: Task<[Int]?, Never>] = [:]
    /// 異なるメトリクスキー間の FIFO 直列化(census は共有 WKWebView を使う
    /// ため、並走するとナビゲーションイベントの取り違えで失敗や
    /// 「1 項目ずれた実測値」のキャッシュ汚染が起きる — レンダラと同方式)
    private var lastMeasure: Task<Void, Never>?
    /// 最後に要求されたキー(リサイズ連打等で放棄された古いキーの
    /// 積み残し実測を、開始前に no-op で捨てるためのゲート)
    private var newestRequestedKey: String?
    /// invalidate 後は新規計測/描画を受け付けない(EPUBPageRasterizer・
    /// EPUBScreenThumbnailRenderer と同じ契約)。これがないと、LRU 追い出しで
    /// invalidate したあとに残った呼び出し元が census.measure / 新しい renderer を
    /// 起動し、不可視ウインドウ・WebContent プロセスを蘇らせてしまう(誰も畳まない)
    private var isInvalidated = false

    public init(publication: EPUBPublication) {
        self.publication = publication
        self.census = EPUBPaginationCensus()
    }

    /// テスト用: fake census を注入するイニシャライザ
    init(publication: EPUBPublication, census: any ScreenPageCensusing,
         renderer: (any ScreenThumbnailRendering)? = nil) {
        self.publication = publication
        self.census = census
        self.renderer = renderer
    }

    /// テスト用: 実測中(合流対象)のメトリクスキー集合。並行要求の登録を
    /// 決定論的に待つため
    func inFlightMeasureKeys() -> Set<String> { Set(measuring.keys) }

    /// テスト用: 実測キャッシュの追い出しと解放を WebKit なしで検証する。
    func cachedMeasureKeys() -> Set<String> { Set(countsCache.keys) }

    /// 画面外のリソース(census とレンダラの不可視ウインドウおよび
    /// WebContent プロセス)を明示的に解放する。**アトラスを手放すとき
    /// (キャッシュからの追い出しなど)は必ず呼ぶこと**。進行中の実測や描画を
    /// 止め、ホストの存続中ずっとプロセスが生き残ることを防ぐ。呼び出し後は
    /// 新しい処理を受け付けず、`screenPlan` / `thumbnail` は nil を返す。
    /// このインスタンスは再利用しないこと。
    ///
    /// Explicitly tears down the offscreen resources (the invisible windows and
    /// WebContent processes of the census and renderer). **Always call this when
    /// releasing the atlas (e.g. on eviction from a cache)** — it stops any
    /// in-progress measurement or render so the processes are not kept alive for
    /// the host's entire lifetime. After this call the atlas refuses further work
    /// (`screenPlan`/`thumbnail` return nil); do not reuse this
    /// instance.
    public func invalidate() {
        isInvalidated = true
        for task in measuring.values { task.cancel() }
        measuring.removeAll()
        countsCache.removeAll()
        countsCacheKeys.removeAll()
        newestRequestedKey = nil
        census.invalidate()
        renderer?.invalidate()
        renderer = nil
    }

    /// 項目ごとのページ数と、その出版物で 1 画面に表示するページ数を返す。
    /// 出版物全体の `rendition:spread` の指定を、両方の値へ不可分に適用する。
    ///
    /// Returns per-item page counts together with the publication-specific
    /// number of pages shown on each screen. The publication-wide
    /// `rendition:spread` preference is applied atomically to both values.
    public func screenPlan(
        metrics: EPUBScreenMetrics
    ) async -> (counts: [Int], pagesPerScreen: Int)? {
        guard !isInvalidated else { return nil }
        let m = metrics.applyingRenditionSpread(
            publication.metadata.rendition.spread)
        let key = m.censusOptionsJSON
        if let cached = countsCache[key] {
            return (cached, m.pagesPerScreen)
        }
        // 合流の前に newestRequestedKey を更新し、待機中の同一キーを
        // 表示中の最新要求へ戻す
        newestRequestedKey = key
        if let running = measuring[key] {
            let counts = await running.value
            guard !isInvalidated else { return nil }
            if let counts {
                return (counts, m.pagesPerScreen)
            }
            // cooViewer-oxr.55: 完了済み nil/cancelled タスクへ合流した最新要求は、
            // 死んだタスクを返さず、この要求自身で新しい実測を開始する。
            if measuring[key] == running {
                measuring[key] = nil
            } else if let replacement = measuring[key] {
                // cooViewer-oxr.55: 別要求が既に始めた生きた再計測へ合流する。
                // その再計測自体の失敗は無限再試行を避けて呼び出し元へ返す。
                guard let counts = await replacement.value, !isInvalidated
                else { return nil }
                return (counts, m.pagesPerScreen)
            }
            guard !isInvalidated, newestRequestedKey == key else { return nil }
        }
        let previous = lastMeasure
        let task = Task(priority: .userInitiated) {
            [census, publication, weak self] () -> [Int]? in
            _ = await previous?.value
            guard self?.newestRequestedKey == key else { return nil }
            return await census.measure(publication: publication, optionsJSON: key,
                                        contentSize: m.contentSize)
        }
        measuring[key] = task
        lastMeasure = Task(priority: .userInitiated) { _ = await task.value }
        let counts = await task.value
        if measuring[key] == task { measuring[key] = nil }
        // キャンセルに応じない実測が遅れて完了しても、解放済みキャッシュを
        // 復活させない。失敗した実測はキャッシュの追い出しにも影響させない。
        guard !isInvalidated, let counts else { return nil }
        if countsCache[key] == nil {
            if countsCacheKeys.count == Self.countsCacheLimit {
                countsCache.removeValue(forKey: countsCacheKeys.removeFirst())
            }
            countsCacheKeys.append(key)
        }
        countsCache[key] = counts
        return (counts, m.pagesPerScreen)
    }

    /// 指定画面のサムネイル(失敗時や `invalidate()` の呼び出し後は nil)。
    ///
    /// Thumbnail for the given screen (nil on failure or after `invalidate()`).
    public func thumbnail(spineIndex: Int, pageInItem: Int,
                          metrics: EPUBScreenMetrics, isDark: Bool,
                          width: CGFloat) async -> CGImage? {
        guard !isInvalidated else { return nil }
        let m = metrics.applyingRenditionSpread(
            publication.metadata.rendition.spread)
        let renderer = self.renderer
            ?? EPUBScreenThumbnailRenderer(publication: publication)
        self.renderer = renderer
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            optionsJSON: m.themedOptionsJSON(isDark: isDark),
            contentSize: m.contentSize, snapshotWidth: width)
    }
}
