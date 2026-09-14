import WebKit

/// スナップショットも JS と同じ期限・取消を適用し、無応答の WebKit 待ちで
/// FIFO と WebView の解放を塞がない。WebKit 自身のエラーはそのまま返す。
@MainActor
func takeOffscreenSnapshot(
    webView: WKWebView, configuration: WKSnapshotConfiguration,
    timeout: Duration = .seconds(5)
) async throws -> CGImage {
    let result: Result<CGImage, any Error>? = await waitForOffscreenResult(
        timeout: timeout
    ) { completion in
        webView.takeSnapshot(with: configuration) { image, error in
            if let error {
                completion(.failure(error))
            } else if let cgImage = image?.cgImage(
                forProposedRect: nil, context: nil, hints: nil) {
                completion(.success(cgImage))
            } else {
                completion(.failure(EPUBPageRasterizer.RasterizeError.snapshotFailed))
            }
        }
    }
    try Task.checkCancellation()
    guard let result else { throw EPUBPageRasterizer.RasterizeError.snapshotFailed }
    return try result.get()
}
