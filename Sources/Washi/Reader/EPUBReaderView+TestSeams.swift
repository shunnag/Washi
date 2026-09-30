import AppKit

/// EPUBReaderView のテスト用の差し替え点と観測点: 実 WebKit なしで
/// 内部状態を置く・読むための internal メンバー。
extension EPUBReaderView {
    /// テスト用: 撮影を経ずに控えを置く
    func setPrefetchedPageCoverForTesting(_ cover: PrefetchedPageCover?) {
        prefetchedPageCover = cover
    }

    /// テスト用: washi world で任意の式を評価する
    func evaluateForTest(_ body: String) async throws -> Any? {
        await callWashiReturning(body)
    }

    /// cooViewer-oxr.54: 回帰テストが非表示中の延期状態を同期的に確認する。
    var hasDeferredVisibleLayout: Bool { pendingVisibleLayout }

    var isPageCensusScheduled: Bool { censusTask != nil }

    var isRepaginationScheduled: Bool { repaginateWork != nil }

    var hasScreenThumbnailRenderer: Bool { thumbnailRenderer != nil }
}
