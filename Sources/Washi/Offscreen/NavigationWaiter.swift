import WebKit

/// didFinish / didFail を async で待つための一時デリゲート。
/// WebContent プロセスの死亡・タイムアウトでも必ず 1 回だけ resume する
/// (EPUBOffscreenWebViewHost を通してラスタライザ・全文ページ census・
/// サムネイルレンダラの 3 者で共用)
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?
    /// continuation を設置する前にキャンセルが着弾したときのフラグ(直列
    /// MainActor 上で install が先に走るので通常は不要だが、多重防御)
    private var cancelledBeforeInstall = false
    /// cooViewer-oxr.46 C33: 待っているナビゲーション。取り消された前の
    /// 読み込みの通知が次の待機へ配達されても取り違えない(設定しなければ
    /// 従来どおり最初に届いた通知で解決する)
    private var expectedNavigation: WKNavigation?
    private var hasExpectation = false

    /// この待機が対象とするナビゲーションを宣言する(load の直後に呼ぶ)。
    func expect(_ navigation: WKNavigation?) {
        expectedNavigation = navigation
        hasExpectation = true
    }

    private func isExpected(_ navigation: WKNavigation?) -> Bool {
        guard hasExpectation else { return true }
        return navigation === expectedNavigation
    }

    /// 取り消し由来のエラーは「失敗」ではない。取り消された前の読み込みの
    /// -999 が次の計測へ配達されると、偽の失敗として累積し、census が
    /// 2 回で停止してしまう(cooViewer-oxr.46 C33)。
    /// EPUBPaginationCensus.mustAbortMeasurement も同じ分類を使う。
    static func isCancellation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled { return true }
        // WebKitErrorFrameLoadInterruptedByPolicyChange
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return true }
        return false
    }

    enum WaitError: Error {
        case timeout
        case contentProcessTerminated
    }

    /// 待機。キャンセルに即応する(タスクを cancel すると 15/30 秒のタイムアウト
    /// 満了を待たず CancellationError で抜ける — census の invalidate 直後に
    /// オフスクリーンが最大 15 秒生き残る/次の census が FIFO で連鎖待ちに
    /// なるのを防ぐ)。タイマは解決時に必ず回収する
    func wait(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeInstall {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resume(throwing: WaitError.timeout)
                }
            }
        } onCancel: {
            // onCancel は @Sendable・非分離 → MainActor へホップして解決する
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    /// cooViewer-oxr.53: 所有者の invalidate から、continuation の設置前後を
    /// 問わず待機を即座にキャンセルする。
    func cancel() {
        cancelledBeforeInstall = true
        resume(throwing: CancellationError())
    }

    private func resume(throwing error: (any Error)? = nil) {
        timeoutTask?.cancel()  // タイムアウトタイマを回収(15/30 秒生き残らせない)
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // オフスクリーンの計測/ラスタライズはコンテナ内(washi-epub)以外へ
        // 遷移しない。meta refresh 等による外部接続を本番ビューと同様に遮断する
        // (本番の decidePolicyFor と同じ方針。本の中身は信頼しない)
        let allowed = navigationAction.request.url?.scheme?.lowercased()
            == EPUBSchemeHandler.scheme
        return (allowed ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isExpected(navigation) else { return }
        resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: any Error) {
        guard isExpected(navigation), !Self.isCancellation(error) else { return }
        resume(throwing: error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        guard isExpected(navigation), !Self.isCancellation(error) else { return }
        resume(throwing: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resume(throwing: WaitError.contentProcessTerminated)
    }
}
