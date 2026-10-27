import Foundation
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

@MainActor
final class EPUBSchemeHandlerTests: XCTestCase {
    /// Washi-1mg: 巨大 entry の展開開始後に止め、CRC まで完走せず取消しが届く。
    func testStopCancelsRunningInflationWithoutCallbacks() async throws {
        let path = "OEBPS/payload.bin"
        let probe = SchemeReadProbe(paths: [path], blocks: false)
        let publication = try Self.makeImageSpinePublication(
            path: "payload.bin", mediaType: "application/octet-stream",
            data: Data(repeating: 0x61, count: 128 << 20), method: 8,
            wrapReader: { ProbedSchemeReader(base: $0, probe: probe) })
        let handler = EPUBSchemeHandler(publication: publication)
        let webView = WKWebView(frame: .zero)
        let stopped = expectation(description: "停止済み要求には完了・失敗を通知しない")
        stopped.isInverted = true
        let task = RecordingSchemeTask(request: URLRequest(
            url: try XCTUnwrap(handler.url(forContainerPath: path)))) { stopped.fulfill() }
        handler.webView(webView, start: task)
        try await waitUntil { probe.started.count == 1 }
        // 読取り入口だけでなく 64 KiB の展開ループに入る時間を取る。
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(probe.completedCount, 0)
        handler.webView(webView, stop: task)
        handler.webView(webView, stop: task)
        try await waitUntil { probe.cancelledCount == 1 }
        await fulfillment(of: [stopped], timeout: 0.05)
        XCTAssertEqual(probe.completedCount, 0)
        XCTAssertEqual(task.callbackCount, 0)
    }

    /// Washi-1mg: 背景処理をゲートで止め、上限・FIFO・待機中の取消しを決定的に検証する。
    func testExtractionLimitFIFOAndQueuedStop() async throws {
        let paths = (0..<7).map { "budget/\($0).bin" }
        let probe = SchemeReadProbe(paths: Set(paths), blocks: true)
        defer { probe.releaseAll() }
        let publication = try Self.makeImageSpinePublication(
            wrapReader: { ProbedSchemeReader(base: $0, probe: probe) })
        let handler = EPUBSchemeHandler(publication: publication)
        let webView = WKWebView(frame: .zero)
        let finished = expectation(description: "停止していない 5 要求が完了する")
        finished.expectedFulfillmentCount = 5
        let tasks = try paths.map { path in
            RecordingSchemeTask(request: URLRequest(
                url: try XCTUnwrap(handler.url(forContainerPath: path)))) {
                    finished.fulfill()
                }
        }
        for task in tasks { handler.webView(webView, start: task) }
        try await waitUntil { probe.started.count >= 4 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.started.count, 4)
        XCTAssertEqual(Set(probe.started), Set(paths.prefix(4)))
        handler.webView(webView, stop: tasks[4])
        handler.webView(webView, stop: tasks[0])
        // 取消しを無視する reader でも、実際に終了するまでは枠を返さない。
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.started.count, 4)
        probe.release(paths[0])
        try await waitUntil { probe.started.count >= 5 }
        XCTAssertEqual(probe.started[4], paths[5])
        probe.release(paths[1])
        try await waitUntil { probe.started.count >= 6 }
        XCTAssertEqual(probe.started[5], paths[6])
        probe.releaseAll()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(probe.maximumActive, 4)
        XCTAssertFalse(probe.started.contains(paths[4]))
        XCTAssertEqual(tasks[0].callbackCount, 0)
        XCTAssertEqual(tasks[4].callbackCount, 0)
        for index in [1, 2, 3, 5, 6] {
            XCTAssertNil(tasks[index].failure)
            XCTAssertEqual(tasks[index].receivedData, Data(paths[index].utf8))
        }
    }

    /// Washi-1mg: 予算超過は文字列化前に素通しし、Range 応答中も main actor を空ける。
    func testOversizedCSSSkipsPolyfillWithoutBlockingMainActor() async throws {
        XCTAssertEqual(EPUBPrefixedCSS.stylesheetByteLimit, 32 << 20)
        let prefix = Data(".tcy { -epub-text-combine-horizontal: all; }".utf8)
        var data = Data(repeating: 0x20, count: EPUBPrefixedCSS.stylesheetByteLimit + 1)
        data.replaceSubrange(0..<prefix.count, with: prefix)
        XCTAssertEqual(EPUBPrefixedCSS.polyfilledStylesheet(data), data)
        let publication = try Self.makeImageSpinePublication(
            path: "style.css", mediaType: " TEXT/CSS ; charset=utf-8", data: data)
        let handler = EPUBSchemeHandler(publication: publication)
        var request = URLRequest(url: try XCTUnwrap(
            handler.url(forContainerPath: "OEBPS/style.css")))
        request.setValue("bytes=0-\(prefix.count - 1)", forHTTPHeaderField: "Range")
        let finished = expectation(description: "巨大 CSS の部分応答が完了する")
        let task = RecordingSchemeTask(request: request) { finished.fulfill() }
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            var longest = Duration.zero
            repeat {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longest = max(longest, now - previous)
                previous = now
            } while !Task.isCancelled
            return longest
        }
        await Task.yield()
        handler.webView(WKWebView(frame: .zero), start: task)
        await fulfillment(of: [finished], timeout: 5)
        heartbeat.cancel()
        let longestPause = await heartbeat.value
        XCTAssertLessThan(longestPause, .milliseconds(250))
        XCTAssertNil(task.failure)
        XCTAssertEqual(task.receivedData, prefix)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.value(
            forHTTPHeaderField: "Content-Range"), "bytes 0-\(prefix.count - 1)/\(data.count)")
        XCTAssertNil(handler.cachedRangeResource)
    }

    /// Washi-1mg: 補完後の payload を保持し、Range 命中時には補完を繰り返さない。
    func testRangeCSSCacheStoresPolyfilledPayload() async throws {
        let source = Data(".tcy { -epub-text-combine-horizontal: all; }".utf8)
        let expected = EPUBPrefixedCSS.polyfilledStylesheet(source)
        XCTAssertNotEqual(source, expected)
        let handler = EPUBSchemeHandler(publication: try Self.makeImageSpinePublication(
            path: "style.css", mediaType: "TEXT/CSS", data: source))
        let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/style.css"))
        for _ in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-\(expected.count - 1)", forHTTPHeaderField: "Range")
            let finished = expectation(description: "補完済み CSS の部分応答が完了する")
            let task = RecordingSchemeTask(request: request) { finished.fulfill() }
            handler.webView(WKWebView(frame: .zero), start: task)
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertNil(task.failure)
            XCTAssertEqual(task.receivedData, expected)
            XCTAssertEqual(handler.cachedRangeResource?.data, expected)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("背景処理が期限内に進まない")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Washi-hgd: 表示・非表示とも autoplay を抑止し、本の状態は WebView ごとに分離する。
    func testReaderAndOffscreenConfigurationsShareHardening() throws {
        let publication = try Self.makeImageSpinePublication()
        for allowsScripts in [false, true] {
            let reader = EPUBReaderView(frame: .zero)
            defer { reader.unload() }
            reader.settings.allowsScriptedContent = allowsScripts
            reader.load(publication: publication)
            let visible = try XCTUnwrap(reader.webView).configuration
            let offscreen = EPUBOffscreenWebViewConfiguration.make(
                allowsScriptedContent: allowsScripts)
            let secondOffscreen = EPUBOffscreenWebViewConfiguration.make(
                allowsScriptedContent: allowsScripts)

            for configuration in [visible, offscreen, secondOffscreen] {
                XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
                XCTAssertEqual(configuration.defaultWebpagePreferences.allowsContentJavaScript,
                               allowsScripts)
                XCTAssertFalse(configuration.websiteDataStore.isPersistent)
            }
            XCTAssertFalse(visible.websiteDataStore === offscreen.websiteDataStore)
            XCTAssertFalse(offscreen.websiteDataStore === secondOffscreen.websiteDataStore)
            XCTAssertFalse(visible.suppressesIncrementalRendering)
            XCTAssertTrue(offscreen.suppressesIncrementalRendering)

            reader.load(publication: publication)
            let rebuilt = try XCTUnwrap(reader.webView).configuration
            XCTAssertFalse(visible.websiteDataStore === rebuilt.websiteDataStore)
            XCTAssertEqual(rebuilt.mediaTypesRequiringUserActionForPlayback, .all)
        }
    }

    /// Washi-hyt: 本のホスト名が一致しても、別 origin になる port / userinfo は受理しない。
    func testContainerPathRejectsPortAndUserInfo() throws {
        let handler = EPUBSchemeHandler(publication: try Self.makeImageSpinePublication())
        let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/images/page.png"))
        XCTAssertEqual(handler.containerPath(for: url), "OEBPS/images/page.png")
        for authority in ["\(handler.instanceID):8080", "evil@\(handler.instanceID)",
                          "@\(handler.instanceID)", "evil:secret@\(handler.instanceID)"] {
            let foreignURL = try XCTUnwrap(URL(
                string: "\(EPUBSchemeHandler.scheme)://\(authority)/OEBPS/images/page.png"))
            XCTAssertNil(handler.containerPath(for: foreignURL), authority)
        }
    }

    /// Washi-hyt: slice の添字は親を引き継ぐが、Range ヘッダはリソースの先頭を 0 とする。
    func testRangeResponseUsesSlicedDataIndices() async throws {
        let handler = EPUBSchemeHandler(publication: try Self.makeImageSpinePublication())
        let data = Data(0..<20)[10..<20]
        XCTAssertEqual(data.startIndex, 10)
        handler.cacheRangeResource(path: "audio.mp3", data: data, mediaType: "audio/mpeg")
        let url = try XCTUnwrap(handler.url(forContainerPath: "audio.mp3"))
        var request = URLRequest(url: url)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let finished = expectation(description: "slice の部分応答が完了する")
        let task = RecordingSchemeTask(request: request) { finished.fulfill() }
        handler.webView(WKWebView(frame: .zero), start: task)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(task.failure)
        let response = try XCTUnwrap(task.response as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(task.receivedData, Data([12, 13, 14, 15]))
    }

    /// Washi-hyt: 全体・部分応答のどちらでも、外部読み込みを制限する CSP を欠かさない。
    func testResponsesIncludeContentSecurityPolicy() async throws {
        for allowsScripts in [false, true] {
            let handler = EPUBSchemeHandler(
                publication: try Self.makeImageSpinePublication(), allowsScripts: allowsScripts)
            let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/images/page.png"))
            let expectedDirectives: Set<String> = [
                "default-src 'self'", "img-src 'self' data:", "media-src 'self' data:",
                "style-src 'self' 'unsafe-inline'", "font-src 'self' data:",
                allowsScripts ? "script-src 'self' 'unsafe-inline'" : "script-src 'none'",
                "connect-src 'none'", "frame-src 'self'",
            ]
            for (range, status) in [(nil as String?, 200), ("bytes=0-3", 206)] {
                var request = URLRequest(url: url)
                request.setValue(range, forHTTPHeaderField: "Range")
                let finished = expectation(description: "CSP 付き応答が完了する")
                let task = RecordingSchemeTask(request: request) { finished.fulfill() }
                handler.webView(WKWebView(frame: .zero), start: task)
                await fulfillment(of: [finished], timeout: 2)

                XCTAssertNil(task.failure)
                let response = try XCTUnwrap(task.response as? HTTPURLResponse)
                XCTAssertEqual(response.statusCode, status)
                let csp = try XCTUnwrap(response.value(
                    forHTTPHeaderField: "Content-Security-Policy"))
                let directives = Set(csp.split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
                XCTAssertEqual(directives, expectedDirectives)
            }
        }
    }

    /// Washi-hyt: CSS は型の大文字・パラメータを正規化して補い、似た型名には適用しない。
    func testCSSMediaTypeIsNormalizedBeforePolyfill() async throws {
        let data = Data(".tcy { -epub-text-combine-horizontal: all; }".utf8)
        for (mediaType, contentType, shouldPolyfill) in [
            ("TEXT/CSS", EPUBMediaType.css, true),
            (" TEXT/CSS ; charset=utf-8", "text/css; charset=utf-8", true),
            ("text/csszzz", "text/csszzz", false),
            ("text/css&#9;junk", "application/octet-stream", false),
            ("text/css&#13;&#10;", "application/octet-stream", false),
            ("text/css; charset=utf-8&#13;&#10;", "application/octet-stream", false),
        ] {
            let publication = try Self.makeImageSpinePublication(
                path: "style.css", mediaType: mediaType, data: data)
            let handler = EPUBSchemeHandler(publication: publication)
            let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/style.css"))
            let finished = expectation(description: "CSS の応答が完了する")
            let task = RecordingSchemeTask(request: URLRequest(url: url)) { finished.fulfill() }
            handler.webView(WKWebView(frame: .zero), start: task)
            await fulfillment(of: [finished], timeout: 2)

            XCTAssertNil(task.failure)
            XCTAssertEqual((task.response as? HTTPURLResponse)?.value(
                forHTTPHeaderField: "Content-Type"), contentType)
            let source = try XCTUnwrap(String(data: task.receivedData, encoding: .utf8))
            XCTAssertEqual(source.contains("text-combine-upright"), shouldPolyfill)
            if !shouldPolyfill { XCTAssertEqual(task.receivedData, data) }
        }
    }

    /// Washi-hyt: 不正な manifest 宣言でも型を明示し、WebKit の sniff に委ねない。
    func testInvalidManifestMediaTypeServesOctetStream() async throws {
        let data = Data("<html><body>untrusted</body></html>".utf8)
        let publication = try Self.makeImageSpinePublication(
            path: "payload.bin", mediaType: "text/html&#13;&#10;X-Injected: 1", data: data)
        let handler = EPUBSchemeHandler(publication: publication)
        let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/payload.bin"))
        let finished = expectation(description: "不正な型の応答が完了する")
        let task = RecordingSchemeTask(request: URLRequest(url: url)) { finished.fulfill() }
        handler.webView(WKWebView(frame: .zero), start: task)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(task.failure)
        let response = try XCTUnwrap(task.response as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertNil(response.value(forHTTPHeaderField: "X-Injected"))
        XCTAssertEqual(task.receivedData, data)
    }

    /// Washi-hyt: 型の比較と charset の付与は、同じ正規化済みの宣言に基づく。
    func testContentTypeNormalizesMediaType() {
        let data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html/>".utf8)
        XCTAssertEqual(EPUBSchemeHandler.contentType(for: " TEXT/CSS ; charset=utf-8", data: data),
                       "text/css; charset=utf-8")
        XCTAssertEqual(EPUBSchemeHandler.contentType(for: "APPLICATION/XHTML+XML", data: data),
                       "application/xhtml+xml; charset=UTF-8")
        XCTAssertEqual(EPUBSchemeHandler.contentType(for: " IMAGE/PNG ", data: data), "image/png")
        XCTAssertEqual(EPUBSchemeHandler.contentType(for: "IMAGE/PNG; foo=bar", data: data), "image/png; foo=bar")
        XCTAssertEqual(EPUBSchemeHandler.contentType(for: "text/plain; charset=Shift_JIS", data: data), "text/plain; charset=Shift_JIS")
    }

    /// Washi-hyt: type/subtype の token 以外は Content-Type として配信しない。
    func testInvalidMediaTypeFallsBackToOctetStream() {
        for mediaType in ["", ";text/html", ";;text/html", "text", "/html", "text/",
                          "text/html/extra", "text/ht ml",
                          "text/css\tjunk", "text/html\r\nX-Injected: 1", "text/html\r\n",
                          "text/html; charset=utf-8\r\nX-Injected: 1", "text/ht\u{7f}ml",
                          "text/(html)", "text/日本語"] {
            XCTAssertEqual(EPUBSchemeHandler.contentType(for: mediaType, data: Data()),
                           "application/octet-stream", mediaType)
        }
        let tokenType = "application/x-test!#$%&'*+-.^_`|~09"
        XCTAssertEqual(EPUBSchemeHandler.contentType(for: tokenType, data: Data()), tokenType)
    }

    /// 単一リソースの予算超過は保持せず、境界値までは再利用できる。
    func testRangeResourceCacheEnforcesByteLimit() throws {
        let handler = EPUBSchemeHandler(publication: try Self.makeImageSpinePublication())
        XCTAssertEqual(handler.rangeResourceCacheByteLimit, 32 * 1024 * 1024)
        let limit = 4 * 1024
        handler.rangeResourceCacheByteLimit = limit
        handler.cacheRangeResource(path: "large.mp4",
                                   data: Data(repeating: 0, count: limit + 1),
                                   mediaType: "video/mp4")
        XCTAssertNil(handler.cachedRangeResource)

        handler.cacheRangeResource(path: "bounded.mp4",
                                   data: Data(repeating: 0, count: limit),
                                   mediaType: "video/mp4")
        XCTAssertEqual(handler.cachedRangeResource?.path, "bounded.mp4")
        XCTAssertEqual(handler.cachedRangeResource?.data.count, limit)
    }

    /// 実際の Range 応答経路でも予算超過を保持せず、要求範囲だけを返す。
    func testOversizedRangeResourceIsServedWithoutCaching() async throws {
        let limit = 4 * 1024
        let data = Data(repeating: 0x5a, count: limit + 1)
        let publication = try Self.makeImageSpinePublication(
            path: "media/large.mp4", mediaType: "video/mp4", data: data)
        let handler = EPUBSchemeHandler(publication: publication)
        handler.rangeResourceCacheByteLimit = limit
        let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/media/large.mp4"))
        var request = URLRequest(url: url)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let finished = expectation(description: "大きなメディアの部分応答が完了する")
        let task = RecordingSchemeTask(request: request) { finished.fulfill() }
        handler.webView(WKWebView(frame: .zero), start: task)
        await fulfillment(of: [finished], timeout: 5)

        XCTAssertNil(task.failure)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(task.receivedData, Data(repeating: 0x5a, count: 4))
        XCTAssertNil(handler.cachedRangeResource)
    }

    /// 明示破棄は何度呼んでも安全で、破棄後の新しい要求は再び保持できる。
    func testClearRangeResourceCacheReleasesResource() throws {
        let handler = EPUBSchemeHandler(publication: try Self.makeImageSpinePublication())
        let data = Data([1, 2, 3])
        handler.cacheRangeResource(path: "audio.mp3", data: data, mediaType: "audio/mpeg")
        XCTAssertEqual(handler.cachedRangeResource?.data, data)
        handler.clearRangeResourceCache()
        XCTAssertNil(handler.cachedRangeResource)
        handler.clearRangeResourceCache()
        XCTAssertNil(handler.cachedRangeResource)
        handler.cacheRangeResource(path: "next.mp3", data: data, mediaType: "audio/mpeg")
        XCTAssertEqual(handler.cachedRangeResource?.path, "next.mp3")
    }

    /// 破棄前に開始した応答は完了させるが、その展開結果でキャッシュを復活させない。
    func testClearedRangeCacheIsNotRefilledByPendingRequest() async throws {
        let handler = EPUBSchemeHandler(publication: try Self.makeImageSpinePublication())
        let url = try XCTUnwrap(handler.url(forContainerPath: "OEBPS/images/page.png"))
        var request = URLRequest(url: url)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let finished = expectation(description: "破棄後も部分応答が完了する")
        let task = RecordingSchemeTask(request: request) { finished.fulfill() }
        handler.webView(WKWebView(frame: .zero), start: task)
        handler.clearRangeResourceCache()
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(task.failure)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(task.receivedData, EPUBFixtures.tinyPNG.subdata(in: 0..<4))
        XCTAssertNil(handler.cachedRangeResource)
    }

    /// 大文字・空白・パラメータを含む SVG の宣言も、画像ラッパーへ変換しない。
    func testSVGSpineURLDoesNotUseImageWrapper() throws {
        for mediaType in [EPUBMediaType.svg, " IMAGE/SVG+XML ; charset=utf-8 "] {
            let publication = try Self.makeImageSpinePublication(
                path: "pages/page.svg", mediaType: mediaType, data: Data("<svg/>".utf8))
            let handler = EPUBSchemeHandler(publication: publication)
            let entry = try XCTUnwrap(publication.readingOrder.first)
            let url = try XCTUnwrap(handler.url(forReadingOrderItem: entry))
            XCTAssertFalse(EPUBSchemeHandler.isImageWrapperURL(url))
            XCTAssertEqual(handler.containerPath(for: url), "OEBPS/pages/page.svg")
        }
    }

    /// SVG は元の文書と MIME 型で配信し、予約クエリ付きでも画像モードにしない。
    /// 外部参照の実際の取得・描画は行わず、スキーム応答だけを検証する。
    func testSVGSpineServesOriginalDocumentEvenWithWrapperQuery() async throws {
        let svg = Data("""
            <?xml version="1.0"?>
            <?xml-stylesheet href="../style.css" type="text/css"?>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <image href="../images/page.png" width="10" height="10"/>
            </svg>
            """.utf8)
        let publication = try Self.makeImageSpinePublication(
            path: "pages/page.svg", mediaType: EPUBMediaType.svg, data: svg)
        let handler = EPUBSchemeHandler(publication: publication)
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: entry))
        let reservedURL = try XCTUnwrap(URL(string: url.absoluteString + "?washi-wrap=1"))
        for requestedURL in [url, reservedURL] {
            let finished = expectation(description: "SVG 文書の応答が完了する")
            let task = RecordingSchemeTask(request: URLRequest(url: requestedURL)) {
                finished.fulfill()
            }
            handler.webView(WKWebView(frame: .zero), start: task)
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertNil(task.failure)
            XCTAssertEqual(task.response?.mimeType, EPUBMediaType.svg)
            XCTAssertEqual(task.receivedData, svg)
        }
    }

    /// cooViewer-oxr.15: 画像 spine の予約 URL は、body が元画像 1 枚だけの
    /// XHTML main resource を応答する。
    func testImageSpineURLServesSynthesizedWrapperResponse() async throws {
        let publication = try Self.makeImageSpinePublication()
        let handler = EPUBSchemeHandler(publication: publication)
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: entry))
        XCTAssertTrue(EPUBSchemeHandler.isImageWrapperURL(url))

        let finished = expectation(description: "wrapper response finished")
        let task = RecordingSchemeTask(request: URLRequest(url: url)) {
            finished.fulfill()
        }
        handler.webView(WKWebView(frame: .zero), start: task)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(task.failure)
        XCTAssertEqual(task.response?.mimeType, EPUBMediaType.xhtml)
        let source = try XCTUnwrap(String(data: task.receivedData,
                                          encoding: .utf8))
        XCTAssertTrue(source.contains("<body><img "))
        XCTAssertTrue(source.contains("OEBPS/images/page.png"))
    }

    /// Shift_JIS 宣言を UTF-8 で上書きせず、宣言値をレスポンスへ渡す
    func testContentTypeUsesDeclaredShiftJIS() throws {
        let source = """
        <?xml version="1.0" encoding="Shift_JIS"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>日本語</body></html>
        """
        let data = try XCTUnwrap(source.data(using: .shiftJIS))
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(
                for: EPUBMediaType.xhtml, data: data).lowercased(),
            "application/xhtml+xml; charset=shift_jis")
    }

    /// 宣言なし UTF-8 は charset を強制せず、XML の既定 UTF-8 判定に任せる
    func testContentTypeLeavesUndeclaredUTF8Unqualified() {
        let data = Data(
            #"<html xmlns="http://www.w3.org/1999/xhtml"><body>日本語</body></html>"#.utf8)
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: EPUBMediaType.xhtml, data: data),
            EPUBMediaType.xhtml)
    }

    /// cooViewer-oxr.12: UTF-8 ではない HTML の meta charset 宣言を採用する。
    func testContentTypeUsesHTMLMetaCharset() throws {
        let cp932 = try XCTUnwrap(
            XMLCharsetDetector.encoding(forCharsetName: "CP932"))
        let direct = try XCTUnwrap(
            #"<!doctype html><html><head><meta charset="windows-31j"></head><body>髙</body></html>"#
                .data(using: cp932))
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: "text/html", data: direct),
            "text/html; charset=windows-31j")

        let httpEquiv = try XCTUnwrap(
            #"<html><head><meta content="text/html; charset=Shift_JIS" http-equiv="Content-Type"></head><body>髙</body></html>"#
                .data(using: cp932))
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: "text/html", data: httpEquiv),
            "text/html; charset=Shift_JIS")
    }

    /// cooViewer-oxr.12: UTF-8 として妥当な本文では古い Shift_JIS meta を
    /// 無視し、WebKit が文字化けしない UTF-8 を明示する。
    func testContentTypeUsesUTF8ForStaleMetaCharset() {
        let data = Data(
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="Shift_JIS"/></head><body>日本語</body></html>"#.utf8)
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: EPUBMediaType.xhtml, data: data),
            "application/xhtml+xml; charset=utf-8")
    }

    /// RFC 7233 の単一 byte range の形式と不正入力を純粋関数で検証する
    func testParseRange() {
        XCTAssertEqual(EPUBSchemeHandler.parseRange("bytes=2-5", total: 10), 2..<6)
        XCTAssertEqual(EPUBSchemeHandler.parseRange("bytes=7-", total: 10), 7..<10)
        XCTAssertEqual(EPUBSchemeHandler.parseRange("bytes=-3", total: 10), 7..<10)
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=0-1,4-5", total: 10))
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=10-", total: 10))
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=5-4", total: 10))
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=0-abc", total: 10))
    }

    private static func makeImageSpinePublication(
        path: String = "images/page.png", mediaType: String = "image/png",
        data: Data = EPUBFixtures.tinyPNG, method: UInt16 = 0,
        wrapReader: ((any ContainerReader) -> any ContainerReader)? = nil
    ) throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:scheme-image</dc:identifier>
                <dc:title>Scheme image</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest><item id="page" href="\(path)"
                media-type="\(mediaType)"/></manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/\(path)", data),
        ]
        let reader = ZipContainerReader(archive: try ZipArchive(
            data: ZipBuilder.build(entries, method: method)))
        return try EPUBPublication(url: URL(fileURLWithPath: "/tmp/scheme-image.epub"),
                                   reader: wrapReader?(reader) ?? reader)
    }
}

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let completion: () -> Void
    private(set) var response: URLResponse?
    private(set) var receivedData = Data()
    private(set) var failure: (any Error)?
    private(set) var callbackCount = 0

    init(request: URLRequest, completion: @escaping () -> Void) {
        self.request = request
        self.completion = completion
    }

    func didReceive(_ response: URLResponse) {
        callbackCount += 1
        self.response = response
    }

    func didReceive(_ data: Data) {
        callbackCount += 1
        receivedData.append(data)
    }

    func didFinish() {
        callbackCount += 1
        completion()
    }

    func didFailWithError(_ error: any Error) {
        callbackCount += 1
        failure = error
        completion()
    }
}

private struct ProbedSchemeReader: ContainerReader {
    let base: any ContainerReader
    let probe: SchemeReadProbe
    var allPaths: [String] { base.allPaths }
    func exists(_ path: String) -> Bool { probe.paths.contains(path) || base.exists(path) }
    func read(_ path: String) throws -> Data {
        guard probe.paths.contains(path) else { return try base.read(path) }
        return try probe.read(path, from: base)
    }
}

/// Washi-1mg: 可変状態は condition で保護し、ゲート待ちでも main actor を使わない。
private final class SchemeReadProbe: @unchecked Sendable {
    let paths: Set<String>
    private let blocks: Bool
    private let condition = NSCondition()
    private var released: Set<String> = []
    private var starts: [String] = []
    private var active = 0
    private var peak = 0
    private var completed = 0
    private var cancelled = 0

    init(paths: Set<String>, blocks: Bool) {
        self.paths = paths
        self.blocks = blocks
    }

    var started: [String] { condition.withLock { starts } }
    var maximumActive: Int { condition.withLock { peak } }
    var completedCount: Int { condition.withLock { completed } }
    var cancelledCount: Int { condition.withLock { cancelled } }

    func release(_ path: String) {
        condition.withLock {
            _ = released.insert(path)
            condition.broadcast()
        }
    }

    func releaseAll() {
        condition.withLock {
            released = paths
            condition.broadcast()
        }
    }

    func read(_ path: String, from base: any ContainerReader) throws -> Data {
        condition.lock()
        starts.append(path)
        active += 1
        peak = max(peak, active)
        while blocks && !released.contains(path) { condition.wait() }
        condition.unlock()
        defer { condition.withLock { active -= 1 } }
        do {
            let data = path.hasPrefix("budget/") ? Data(path.utf8) : try base.read(path)
            condition.withLock { completed += 1 }
            return data
        } catch {
            if error is CancellationError { condition.withLock { cancelled += 1 } }
            throw error
        }
    }
}
