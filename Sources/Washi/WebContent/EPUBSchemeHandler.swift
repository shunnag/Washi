import Foundation
import WebKit

/// EPUB コンテナ内のリソースを WKWebView に配信するカスタムスキームハンドラ。
/// URL の形式: washi-epub://<インスタンス ID>/<コンテナ内パス>
/// コンテナ内パスはパーセント符号化する。
///
/// Custom scheme handler that serves resources inside an EPUB container to a WKWebView.
/// URL form: washi-epub://<instance ID>/<container path (percent-encoded)>
///
/// 実運用の経験に基づく設計上の判断:
///
/// Design decisions (grounded in real-world operational experience):
///
/// - 応答はすべてメインスレッドで行う(WKURLSchemeTask の要件)。展開だけを
///   バックグラウンドで実行し、応答前には必ずタスクがまだ有効かを確かめる
///   (停止後に応答すると NSInternalInconsistencyException でクラッシュする)。
///   All responses happen on the main thread (a WKURLSchemeTask requirement). Only the
///   extraction runs in the background, and before responding we always verify the task
///   is still alive (responding after a stop crashes with NSInternalInconsistencyException).
/// - MIME 型は manifest の宣言に基づき明示する(スキームハンドラの応答では
///   内容から型を推測しない。XHTML が XML として解析されるのは
///   application/xhtml+xml で配信した場合だけ)。
///   The MIME type is stated explicitly from the manifest declaration (scheme-handler
///   responses do no sniffing; XHTML is only XML-parsed when served as application/xhtml+xml).
/// - CSP ヘッダで外部読み込みとスクリプトへの防御を重ねる(本は信頼しない)。
///   The CSP header gives defense-in-depth against external loads and scripts (the book is untrusted).
/// - audio/video には Range 要求が来るため、206 の部分応答に対応する。
///   audio/video receive Range requests, so 206 partial responses are supported.
@MainActor
public final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "washi-epub"
    private static let imageWrapperQueryName = "washi-wrap"
    /// 既定は 32 MiB。テストではインスタンスごとに小さい予算で境界条件を検証する。
    var rangeResourceCacheByteLimit = 32 * 1024 * 1024

    let publication: EPUBPublication
    /// この Web ビューインスタンスのホスト名(本ごとに一意 = オリジン分離)
    let instanceID: String
    /// scripted コンテンツを許可するか(CSP の script-src に反映)
    let allowsScripts: Bool

    // 本文と衝突しない、ビューごとに生成した連続スクロール用の文書。
    var scrollDocumentPath: String { "__washi-scroll-\(instanceID).xhtml" }
    var scrollDocumentURL: URL? { url(forContainerPath: scrollDocumentPath) }

    private var liveTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private typealias ResourcePayload = (data: Data, mediaType: String)
    // Washi-1mg: detached は外側の取消しを継がないため、stop で両方を止める。
    private var extractionTasks: [ObjectIdentifier: Task<ResourcePayload?, Never>] = [:]
    // Washi-1mg: 画像・CSS 等を並行して読みつつ、最大 512 MiB の展開が要求数だけ
    // 同時確保されないよう 4 本に絞る。枠は取消要求時でなく背景処理の終了時に返す。
    /// Washi-1mg: 構成時に設定し、要求の処理中は変更しない。
    var extractionLimit = 4
    private var activeExtractionCount = 0
    private var extractionWaiters: [
        (id: ObjectIdentifier, continuation: CheckedContinuation<Bool, Never>)
    ] = []

    /// 直近に Range 要求で展開したリソース(1件)。audio/video のシークは同じ
    /// ファイルへ Range 要求を繰り返すが、各要求ごとに publication.resource(at:) が
    /// エントリ全体を再 inflate + CRC していた(cooViewer-ebm)。展開結果を1件だけ
    /// 保持し、同一パスの後続 Range は再展開せず slice して返す。非 Range
    /// (XHTML/画像)は再要求されないので載せず、メディアと thrash させない。
    /// @MainActor なのでロック不要
    private(set) var cachedRangeResource: (path: String, data: Data, mediaType: String)?
    private var rangeResourceCacheGeneration: UInt = 0

    public init(publication: EPUBPublication, allowsScripts: Bool = false) {
        self.publication = publication
        self.instanceID = UUID().uuidString.lowercased()
        self.allowsScripts = allowsScripts
    }

    /// 抽出本文キャッシュと同様に、予算を超える単一リソースは保持しない。
    /// 大きなメディアも応答自体は妨げず、要求ごとに展開して必要範囲を返す。
    func cacheRangeResource(path: String, data: Data, mediaType: String) {
        guard data.count <= rangeResourceCacheByteLimit else { return }
        cachedRangeResource = (path, data, mediaType)
    }

    /// 保持中の展開データを破棄する。処理中の応答は継続するが、破棄前に始めた
    /// 展開が完了しても再保持しないよう世代を進める。
    func clearRangeResourceCache() {
        cachedRangeResource = nil
        rangeResourceCacheGeneration &+= 1
    }

    /// コンテナ内パスを、この本の URL に変換する。
    ///
    /// Container path → this book's URL.
    public func url(forContainerPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = instanceID
        components.path = "/" + path
        return components.url
    }

    /// 読書順の項目を WebKit で開く URL。ラスタ画像 spine には単一画像の
    /// ページレイアウトを適用できる合成 XHTML を使う。
    func url(forReadingOrderItem entry: ReadingOrderItem) -> URL? {
        guard var components = url(forContainerPath: entry.resolvedContainerPath)
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        else { return nil }
        guard Self.requiresImageWrapper(entry.resolvedItem.mediaType) else {
            return components.url
        }
        // cooViewer-oxr.15: 生画像を main resource として読む代わりに、
        // ReaderScripts の既存 image-page CSS 経路へ載せる予約 URL を発行する。
        components.queryItems = [URLQueryItem(
            name: Self.imageWrapperQueryName, value: "1")]
        return components.url
    }

    /// URL をコンテナ内パスに変換する(この本に属さなければ nil)。
    ///
    /// URL → container path (nil if it does not belong to this book).
    public func containerPath(for url: URL) -> String? {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host()?.lowercased() == instanceID,
              url.port == nil, url.user() == nil else { return nil }
        let path = url.path(percentEncoded: false)
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let path = containerPath(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let publication = self.publication
        let cacheGeneration = rangeResourceCacheGeneration
        liveTasks[id] = Task { [weak self] in
            if let self, path == self.scrollDocumentPath {
                guard self.liveTasks[id] != nil else { return }
                self.liveTasks[id] = nil
                self.reply(to: urlSchemeTask, url: url,
                           data: EPUBScrollDocument.containerData,
                           mediaType: EPUBMediaType.xhtml, rangeHeader: nil)
                return
            }
            if Self.isImageWrapperURL(url),
               let entry = publication.readingOrder.first(where: {
                   $0.resolvedContainerPath == path
                       && Self.requiresImageWrapper($0.resolvedItem.mediaType)
               }),
               let resourceURL = self?.url(forContainerPath: path),
               let wrapper = Self.imageWrapperData(
                   imageURL: resourceURL, title: entry.resolvedItem.id)
            {
                guard let self, self.liveTasks[id] != nil else { return }
                self.liveTasks[id] = nil
                self.reply(to: urlSchemeTask, url: url, data: wrapper,
                           mediaType: EPUBMediaType.xhtml, rangeHeader: nil)
                return
            }
            // 直近 Range リソースの命中(メディアのシーク連打)は再展開せず即応答
            if let self, let cached = self.cachedRangeResource, cached.path == path {
                guard self.liveTasks[id] != nil else { return }  // stop 済み
                self.liveTasks[id] = nil
                self.reply(to: urlSchemeTask, url: url, data: cached.data,
                           mediaType: cached.mediaType, rangeHeader: rangeHeader)
                return
            }
            guard let self, await self.acquireExtractionSlot(for: id) else { return }
            // 待機中に stop された場合は、予約された枠を返して展開を始めない。
            guard self.liveTasks[id] != nil, !Task.isCancelled else {
                self.releaseExtractionSlot()
                return
            }
            // Washi-1mg: CSS も同じ背景処理で補い、Range キャッシュには適用済みの
            // データを保持する。命中時の再走査・再複製とメインスレッドの占有を避ける。
            let extraction = Task.detached(priority: .userInitiated) {
                () -> ResourcePayload? in
                guard !Task.isCancelled,
                      var payload = try? publication.resource(at: path),
                      !Task.isCancelled else { return nil }
                // ヘッダ検証で octet-stream になる制御文字付き宣言も、従来どおり補わない。
                if EPUBMediaType.normalized(payload.mediaType) == EPUBMediaType.css,
                   !payload.mediaType.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) {
                    payload.data = EPUBPrefixedCSS.polyfilledStylesheet(payload.data)
                }
                return Task.isCancelled ? nil : payload
            }
            self.extractionTasks[id] = extraction
            let payload = await extraction.value
            self.extractionTasks[id] = nil
            self.releaseExtractionSlot()
            guard self.liveTasks[id] != nil else { return }  // stop 済み
            self.liveTasks[id] = nil
            guard let payload else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            // Range 要求(メディアのシーク)は同一ファイルへ繰り返し来るので、
            // 展開結果を1件だけ保持する(cooViewer-ebm)。非 Range は載せない
            if rangeHeader != nil,
               self.rangeResourceCacheGeneration == cacheGeneration {
                self.cacheRangeResource(path: path, data: payload.data,
                                        mediaType: payload.mediaType)
            }
            self.reply(to: urlSchemeTask, url: url,
                       data: payload.data, mediaType: payload.mediaType,
                       rangeHeader: rangeHeader)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        liveTasks[id]?.cancel()
        extractionTasks[id]?.cancel()
        liveTasks[id] = nil  // 以後この task へは決して応答しない
        if let index = extractionWaiters.firstIndex(where: { $0.id == id }) {
            extractionWaiters.remove(at: index).continuation.resume(returning: false)
        }
    }

    private func acquireExtractionSlot(for id: ObjectIdentifier) async -> Bool {
        guard liveTasks[id] != nil, !Task.isCancelled else { return false }
        if activeExtractionCount < extractionLimit {
            activeExtractionCount += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            extractionWaiters.append((id, continuation))
        }
    }

    private func releaseExtractionSlot() {
        activeExtractionCount -= 1
        // Washi-1mg: MainActor 上で FIFO の先頭へ枠を予約してから再開する。
        // 再開待ちの間に新しい要求が割り込んでも、同時数と順番を保つ。
        if !extractionWaiters.isEmpty {
            activeExtractionCount += 1
            extractionWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    static func contentType(for mediaType: String, data: Data) -> String {
        // Washi-hyt: 制御文字でヘッダが捨てられ、WebKit の型推測へ戻るのを防ぐ。
        guard !mediaType.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
            return "application/octet-stream"
        }
        let type = EPUBMediaType.normalized(mediaType)
        let parts = type.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                switch byte {
                case 0x30...0x39, 0x61...0x7a: return true
                default: return "!#$%&'*+-.^_`|~".utf8.contains(byte)
                }
            }
        }) else { return "application/octet-stream" }
        // Washi-hyt: 宣言 charset を落として WebKit に推測させないよう、
        // charset を補わない経路では元のパラメータを保つ。
        let parameters = mediaType.firstIndex(of: ";").map {
            mediaType[$0...].trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let contentType = type + parameters
        guard EPUBMediaType.isTextual(type) else { return contentType }
        let isXML = type == "application/xml" || type.hasSuffix("+xml")
        if isXML, let charset = XMLCharsetDetector.declaredCharsetName(
            in: data, includesHTMLMeta: false)
        {
            return "\(type); charset=\(charset)"
        }

        guard type == "text/html" || type == EPUBMediaType.xhtml,
              let charset = XMLCharsetDetector.declaredCharsetName(in: data)
        else { return contentType }
        // cooViewer-oxr.12: UTF-8 として正しい本文では古い meta 宣言を採用せず、
        // WebKit が誤った Shift_JIS 等で再解釈しないよう明示的に UTF-8 を返す。
        if String(data: data, encoding: .utf8) != nil {
            return "\(type); charset=utf-8"
        }
        return "\(type); charset=\(charset)"
    }

    static func isImageWrapperURL(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == imageWrapperQueryName && $0.value == "1" }
            ?? false
    }

    private static func requiresImageWrapper(_ value: String) -> Bool {
        let mediaType = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        // SVG は外部 CSS・画像・フォントを参照するコンテンツ文書なので、
        // 画像モードに制限する <img> へ包まず main resource として配信する。
        return mediaType.hasPrefix("image/") && mediaType != EPUBMediaType.svg
    }

    static func imageWrapperData(imageURL: URL, title: String) -> Data? {
        func escaped(_ source: String) -> String {
            source
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        // cooViewer-oxr.15: body を画像 1 枚だけに保ち、既存の image-page
        // 判定と中央寄せ CSS をそのまま再利用する。
        // roll は自然寸法をそのまま使うため、ブラウザ既定の余白と行の隙間を除く。
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>\(escaped(title))</title>
                <style>html, body { margin: 0; padding: 0; } img { display: block; }</style>
              </head>
              <body><img src="\(escaped(imageURL.absoluteString))" alt=""/></body>
            </html>
            """
        return document.data(using: .utf8)
    }

    private func reply(to task: any WKURLSchemeTask, url: URL,
                       data: Data, mediaType: String, rangeHeader: String?) {
        let scriptSource = allowsScripts ? "'self' 'unsafe-inline'" : "'none'"
        // cooViewer-oxr.46 C30: Cache-Control を付けない。非 HTTP スキームの
        // サブリソースへ WebKit が与える無期限鮮度を no-store が打ち消しており、
        // 章送り・census 全項目・サムネイルのたびに同じ CSS/フォントを再 inflate
        // していた。ホスト名は本ごとの UUID なので別の本と取り違えることはなく、
        // データストアは nonPersistent なのでディスクにも残らない。
        var headers: [String: String] = [
            "Content-Security-Policy":
                "default-src 'self'; img-src 'self' data:; media-src 'self' data:; "
                + "style-src 'self' 'unsafe-inline'; font-src 'self' data:; "
                // cooViewer-oxr.46 C50: frame-src は 'self'。'none' だと同じ
                // コンテナ内の iframe(EPUB 3.3 が認める非スクリプトのものを
                // 含む)まで空枠になる。外部への埋め込みは default-src 'self' と
                // オリジン分離(ホスト名が本ごとの UUID)で塞がったまま。
                + "script-src \(scriptSource); connect-src 'none'; frame-src 'self'",
        ]
        let mediaType = Self.contentType(for: mediaType, data: data)
        headers["Content-Type"] = mediaType

        // Range 要求(audio/video のシーク)には 206 で応える
        if let rangeHeader, rangeHeader.hasPrefix("bytes="),
           let range = Self.parseRange(rangeHeader, total: data.count) {
            let base = data.startIndex
            let slice = data.subdata(in: (base + range.lowerBound)..<(base + range.upperBound))
            headers["Content-Length"] = String(slice.count)
            headers["Accept-Ranges"] = "bytes"
            headers["Content-Range"] =
                "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            guard let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: headers) else {
                task.didFailWithError(URLError(.cannotParseResponse))
                return
            }
            task.didReceive(response)
            task.didReceive(slice)
            task.didFinish()
            return
        }

        headers["Content-Length"] = String(data.count)
        headers["Accept-Ranges"] = "bytes"
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// "bytes=a-b" / "bytes=a-" / "bytes=-suffix" の単一レンジのみ対応
    static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard total > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }  // 複数レンジは全体応答へ
        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            // 末尾 suffix 形式
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            let start = max(0, total - suffix)
            return start..<total
        }
        guard let start = Int(parts[0]), start >= 0, start < total else { return nil }
        let end: Int
        if parts[1].isEmpty {
            end = total - 1
        } else {
            // RFC 7233 の byte-range-spec は数値の終端を必須とする。
            // 不正値を 0 とみなさず Range 自体を無視する。
            guard let parsedEnd = Int(parts[1]), parsedEnd >= 0 else { return nil }
            end = min(parsedEnd, total - 1)
        }
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}
