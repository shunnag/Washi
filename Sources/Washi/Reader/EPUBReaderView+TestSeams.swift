import AppKit

/// EPUBReaderView のテスト用の差し替え点と観測点: 実 WebKit なしで
/// 内部状態を置く・読むための internal メンバー。
extension EPUBReaderView {
    /// テスト用: 撮影を経ずに控えを置く
    func setPrefetchedPageCoverForTesting(_ cover: PrefetchedPageCover?) {
        pageCover.prefetchedPageCover = cover
    }

    /// テスト用: washi world で任意の式を評価する。callWashi と違って JS の
    /// 失敗を握りつぶさず投げるので、テストが JS エラーに気づける
    func evaluateForTest(_ body: String) async throws -> Any? {
        guard let webView else { return nil }
        return try await webView.callAsyncJavaScript(
            body, arguments: [:], in: nil, contentWorld: WashiContentWorld.world)
    }

    // cooViewer-oxr.54
    /// テスト用: 回帰テストが非表示中の延期状態を同期的に確認する。
    var hasDeferredVisibleLayout: Bool { repagination.pendingVisibleLayout }

    /// テスト用: census の実測タスクが予約されているか
    var isPageCensusScheduled: Bool { census.task != nil }

    /// テスト用: 再ページ割りが予約されているか
    var isRepaginationScheduled: Bool { repagination.repaginateWork != nil }

    /// テスト用: サムネイルレンダラが生きているか
    var hasScreenThumbnailRenderer: Bool { thumbnailRenderer != nil }

    /// テスト用: WebContent 終了後の再読み込みが予約または保留されているか
    var hasPendingWebContentReload: Bool {
        webContentReload.task != nil || webContentReload.pendingDelay != nil
    }
}
