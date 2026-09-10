import WebKit

/// cooViewer-oxr.88: オフスクリーン描画に使う WebView の共通構成。
@MainActor
enum EPUBOffscreenWebViewConfiguration {
    static func make(allowsScriptedContent: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            allowsScriptedContent
        EPUBScriptedContentHardening.install(
            in: configuration.userContentController,
            allowsScriptedContent: allowsScriptedContent)
        // cooViewer-oxr.88: 不可視の census / thumbnail / rasterizer では、
        // 本文の autoplay が音声・動画を勝手に再生しないよう全媒体を止める。
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        return configuration
    }
}

/// cooViewer-oxr.53/62: FIFO の先行 Task 完了待ちを、呼び出し元の
/// キャンセルで直ちに打ち切るための競合状態。
@MainActor
private final class EPUBOffscreenJobJoinRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// cooViewer-oxr.53/62: 非構造化 FIFO の先行ジョブを待つ間にも、現在の
/// ジョブのキャンセルへ即応する。
@MainActor
func waitForOffscreenPredecessor(_ predecessor: Task<Void, Never>?) async
    -> Bool {
    guard let predecessor else { return !Task.isCancelled }
    let race = EPUBOffscreenJobJoinRace()
    let observer = Task { @MainActor in
        await predecessor.value
        race.finish(true)
    }
    let completed = await withTaskCancellationHandler {
        await race.wait()
    } onCancel: {
        observer.cancel()
        Task { @MainActor in race.finish(false) }
    }
    observer.cancel()
    return completed && !Task.isCancelled
}

/// WebKit の応答と Swift 側の打ち切りのうち、先着だけを採用する。
@MainActor
private final class EPUBOffscreenJavaScriptRace<Value: Sendable> {
    private var isFinished = false
    private var result: Value?
    private var continuation: CheckedContinuation<Value?, Never>?

    func wait() async -> Value? {
        if isFinished { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ result: Value?) {
        guard !isFinished else { return }
        isFinished = true
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

/// JS の完了コールバックを有界に待つ。タイムアウト・キャンセル時は nil。
/// 非同期版を子 Task に閉じ込めると、キャンセル非対応の WebKit 待ちが
/// WebView を保持し続けるため、応答側は競合状態への弱参照だけを持つ。
@MainActor
func waitForOffscreenJavaScript<Value: Sendable>(
    // ラスタライザと同じ 5 秒で打ち切り、JS 側のタイマごと WebKit が
    // 無応答でも FIFO と要求の defer を進め、20 秒のアイドル解放を可能にする。
    timeout: Duration = .seconds(5),
    timeoutScheduler: EPUBOffscreenIdleReleaseTimer.Scheduler =
        EPUBOffscreenIdleReleaseTimer.continuousScheduler,
    start: (_ completion: @escaping @MainActor @Sendable (Value) -> Void) -> Void
) async -> Value? {
    guard !Task.isCancelled else { return nil }
    let race = EPUBOffscreenJavaScriptRace<Value>()
    let cancelTimeout = timeoutScheduler(timeout) { [weak race] in
        race?.finish(nil)
    }
    defer { cancelTimeout() }
    return await withTaskCancellationHandler {
        guard !Task.isCancelled else { return nil }
        start { [weak race] result in
            race?.finish(result)
        }
        return await race.wait()
    } onCancel: {
        Task { @MainActor in race.finish(nil) }
    }
}
