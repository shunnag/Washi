import Foundation

/// 共有する 1 つの WKWebView を使う画面外ジョブを FIFO で完全に直列化する
/// (ラスタライザとサムネイルレンダラで共用)。ジョブ本体は連結した Task の
/// **内側**で実行する(外へ出すと直列化が崩れ、並行呼び出しが互いの
/// ナビゲーションを上書きして NavigationWaiter が永久待ちになる)。
///
/// cooViewer-oxr.53/62: キャンセルされた待機ジョブが先行ジョブより先に
/// 終了しても次の要求が先行処理を追い越さないよう barrier を残し、
/// 呼び出し元のキャンセルを非構造化ジョブへ明示的に伝播する。
/// EPUBScreenAtlas の計測連結(newestRequestedKey による打ち切りと同一キーの
/// 合流)は別の契約なので、ここには寄せない。
@MainActor
final class EPUBOffscreenJobQueue {
    /// 直列化: 直前の要求が終わるまで次を待たせる
    private var lastJob: Task<Void, Never>?
    /// 待機中・実行中のジョブの取り消し手段(cancelAll 用)
    private var jobs: [UUID: () -> Void] = [:]

    /// 待機中・実行中のジョブが 1 つもないか(アイドル解放の判定用)。
    var isIdle: Bool { jobs.isEmpty }

    /// ジョブを FIFO の末尾に積み、その結果を返す。先行ジョブの待ちが
    /// キャンセルで打ち切られたときは CancellationError を投げる。
    /// 優先度は既定で userInitiated(低優先度の呼び出し元 — 例: .utility の
    /// サムネイル先読み — の QoS を継ぐと、WebKit への JS 実行が応答しない
    /// ことがある。EPUBScreenThumbnailRenderer で実測した逆転)
    func enqueue<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = lastJob
        let job = Task(priority: priority) { () throws -> T in
            guard await waitForOffscreenPredecessor(previous) else {
                throw CancellationError()
            }
            return try await body()
        }
        let jobID = UUID()
        jobs[jobID] = { job.cancel() }
        defer { jobs[jobID] = nil }
        // cooViewer-oxr.53: キャンセルされた待機ジョブが先行ジョブより先に
        // 終了しても、次の要求が先行描画を追い越さない FIFO barrier を残す。
        lastJob = Task(priority: priority) {
            _ = await previous?.value
            _ = try? await job.value
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            // cooViewer-oxr.53: 非構造化 FIFO ジョブへ呼び出し元の
            // キャンセルを明示的に伝播する。
            job.cancel()
        }
    }

    /// 失敗を nil で表す非 throwing 版(サムネイル用: 一覧側は空セルの
    /// まま先へ進める)。先行ジョブの待ちが打ち切られたときも nil。
    func enqueue<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @MainActor () async -> T?
    ) async -> T? {
        let previous = lastJob
        let job = Task(priority: priority) { () -> T? in
            guard await waitForOffscreenPredecessor(previous) else { return nil }
            return await body()
        }
        let jobID = UUID()
        jobs[jobID] = { job.cancel() }
        defer { jobs[jobID] = nil }
        // cooViewer-oxr.62: キャンセルされた待機ジョブが先行ジョブより先に
        // 終了しても、次の要求が先行描画を追い越さない FIFO barrier を残す。
        lastJob = Task(priority: priority) {
            _ = await previous?.value
            _ = await job.value
        }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            // cooViewer-oxr.62: 非構造化 FIFO ジョブへ呼び出し元の
            // キャンセルを明示的に伝播する。
            job.cancel()
        }
    }

    /// 待機中・実行中のジョブと barrier をすべて取り消す(所有者の invalidate 用)。
    func cancelAll() {
        lastJob?.cancel()
        for cancel in jobs.values { cancel() }
        jobs.removeAll()
        lastJob = nil
    }

    /// cooViewer-oxr.68: アイドル解放で、完了済みの FIFO 連結への参照を捨てる
    /// (barrier が保持する最後の結果画像も手放す)。ジョブが残っているときは
    /// 呼ばないこと。
    func clearChain() {
        lastJob = nil
    }
}
