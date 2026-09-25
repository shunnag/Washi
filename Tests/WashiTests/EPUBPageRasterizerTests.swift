import AppKit
import WebKit
import XCTest
@testable import Washi

/// cooViewer-oxr.2: 非表示ウインドウでも FXL ラスタライズが完了すること。
@MainActor
final class EPUBPageRasterizerTests: XCTestCase {
    func testSingleImageFixedLayoutPageReturns() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-image.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertNotNil(info.simpleImagePath)
        try await assertRasterizedPage(publication: publication,
                                       viewport: CGSize(width: 1200, height: 1920))
    }

    func testComplexFixedLayoutPageReturns() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(Self.complexFixedLayoutEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-complex.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertNil(info.simpleImagePath)
        try await assertRasterizedPage(publication: publication,
                                       viewport: CGSize(width: 600, height: 800))
    }

    /// cooViewer-oxr.50: device-* viewport は従来の 1200x1600 既定値でなく、
    /// 呼び出し元が要求した描画先の縦横比へ従う。
    func testDeviceSizedViewportUsesRequestedRenderSize() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(Self.deviceSizedFixedLayoutEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-device.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertTrue(info.viewportIsDeviceSized)
        XCTAssertNil(info.viewportSize)
        try await assertRasterizedPage(
            publication: publication, viewport: CGSize(width: 900, height: 450),
            deviceViewportSize: CGSize(width: 900, height: 450))
    }

    /// cooViewer-oxr.53: ナビゲーション開始直後の invalidate は、30 秒の
    /// NavigationWaiter タイムアウトを待たずレンダー要求を終了させる。
    func testInvalidateDuringRequestReturnsWithinOneSecond() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(Self.complexFixedLayoutEntries(), method: 8),
            displayURL: URL(
                fileURLWithPath: "/tmp/washi-rasterizer-invalidate.epub"))
        let rasterizer = EPUBPageRasterizer(publication: publication)
        let task = Task { @MainActor in
            try? await rasterizer.renderPage(
                atSpineIndex: 0, maxPixelSize: 300)
        }
        try? await Task.sleep(for: .milliseconds(5))
        let invalidatedAt = ContinuousClock.now

        rasterizer.invalidate()
        let image = await task.value

        XCTAssertNil(image)
        XCTAssertLessThan(ContinuousClock.now - invalidatedAt, .seconds(1))
    }

    /// 初回描画が終わった後も、本の外への遅延遷移を許可しない。
    /// about:blank を使い、外部ネットワークなしで実際のナビゲーションを検証する。
    func testLateNavigationRemainsRestrictedAfterRendering() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(Self.complexFixedLayoutEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-policy.epub"))
        let rasterizer = EPUBPageRasterizer(publication: publication)
        defer { rasterizer.invalidate() }
        do {
            _ = try await rasterizer.renderPage(atSpineIndex: 0, maxPixelSize: 120)
        } catch {
            return try failOrSkipWebKitTest("WKWebView による初期描画を実行できません: \(error)")
        }
        let webView = try XCTUnwrap(rasterizer.webView)
        let checked = expectation(description: "描画後の遷移判定")
        let probe = LateNavigationPolicyProbe(
            forwarding: webView.navigationDelegate as? NavigationWaiter,
            checked: checked)
        webView.navigationDelegate = probe

        webView.load(URLRequest(url: try XCTUnwrap(URL(string: "about:blank"))))
        await fulfillment(of: [checked], timeout: 5)

        XCTAssertEqual(probe.policy, .cancel)
    }

    /// JS と JS 側タイマーが応答しなくても、Swift の期限後に戻った処理が
    /// WebView を保持し続けないこと。テスト後は残った Promise も解決する。
    func testReadinessTimeoutDoesNotRetainWebView() async throws {
        let testStart = ContinuousClock.now
        let views = NSHashTable<WKWebView>.weakObjects()
        let windows = NSHashTable<NSWindow>.weakObjects()
        var renderDone: ContinuousClock.Instant?
        var jsInstallDone: ContinuousClock.Instant?
        var readinessDone: ContinuousClock.Instant?
        var invalidateDone: ContinuousClock.Instant?
        var renderTrace = EPUBPageRasterizer.RenderTrace()
        defer {
            for view in views.allObjects {
                view.callAsyncJavaScript(
                    "globalThis.__washiResolveReadiness?.(); return true;",
                    arguments: [:], in: nil, in: .defaultClient,
                    completionHandler: nil)
            }
        }
        func exerciseTimeout() async throws {
            let publication = try EPUBPublication(
                data: ZipBuilder.build(Self.complexFixedLayoutEntries(), method: 8),
                displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-readiness.epub"))
            let rasterizer = EPUBPageRasterizer(publication: publication)
            defer {
                rasterizer.invalidate()
                invalidateDone = .now
            }
            do {
                _ = try await rasterizer.renderPage(atSpineIndex: 0, maxPixelSize: 120)
            } catch {
                return try failOrSkipWebKitTest("WKWebView による初期描画を実行できません: \(error)")
            }
            renderDone = .now
            renderTrace = rasterizer.lastRenderTrace
            let view = try XCTUnwrap(rasterizer.webView)
            views.add(view)
            if let window = rasterizer.window { windows.add(window) }
            _ = try await view.callAsyncJavaScript(
                """
                const pending = new Promise(resolve => {
                    globalThis.__washiResolveReadiness = resolve;
                });
                Object.defineProperty(document, 'fonts', {value: {ready: pending}});
                globalThis.setTimeout = () => 0;
                return true;
                """,
                arguments: [:], in: nil, contentWorld: .defaultClient)
            jsInstallDone = .now
            await rasterizer.waitForPostLoadReadiness(
                webView: view, timeout: .milliseconds(20))
            readinessDone = .now
        }

        try await exerciseTimeout()
        // Washi-cfm: 従来の 10 秒の判定を保存し、追加の診断で解放されても成功にしない。
        let start = ContinuousClock.now
        var releasePollCount = 0
        for _ in 0..<500 {
            if autoreleasepool(invoking: { views.allObjects.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(20))
            releasePollCount += 1
        }
        let releaseDone = ContinuousClock.now
        let elapsed = releaseDone - start
        let releasedWithinTenSeconds = autoreleasepool(invoking: { views.allObjects.isEmpty })
        if releaseDone - testStart > .seconds(1) || elapsed > .milliseconds(500)
            || !releasedWithinTenSeconds {
            func duration(from start: ContinuousClock.Instant?,
                          to end: ContinuousClock.Instant?) -> String {
                guard let start, let end else { return "unavailable" }
                return "\(end - start)"
            }
            func relative(_ instant: ContinuousClock.Instant?) -> String {
                duration(from: testStart, to: instant)
            }
            var lines = [
                "readiness timeout diagnostics",
                "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "total through release poll: \(releaseDone - testStart)",
                "render: \(duration(from: testStart, to: renderDone)); done at +\(relative(renderDone))",
                "JS install: \(duration(from: renderDone, to: jsInstallDone)); done at +\(relative(jsInstallDone))",
                "readiness: \(duration(from: jsInstallDone, to: readinessDone)); done at +\(relative(readinessDone))",
                "invalidate: \(duration(from: readinessDone, to: invalidateDone)); done at +\(relative(invalidateDone))",
                "render trace (+test start):",
                "  prepared: \(relative(renderTrace.prepared))",
                "  didFinish: \(relative(renderTrace.didFinish))",
                "  readinessEnd: \(relative(renderTrace.readinessEnd))",
                "  snapshotEnd: \(relative(renderTrace.snapshotEnd))",
                "  readinessTimedOut: \(renderTrace.readinessTimedOut.map { String($0) } ?? "unavailable")",
                "release: \(elapsed); polls: \(releasePollCount); released within 10 s: \(releasedWithinTenSeconds)",
                "offscreen window alive: \(autoreleasepool { !windows.allObjects.isEmpty })",
            ]
            if !releasedWithinTenSeconds {
                // Washi-cfm: 生存確認とログ取得の間も弱参照だけで 20 ms ごとに観測する。
                let lateRelease = Task { @MainActor in
                    while ContinuousClock.now - start < .seconds(30) {
                        if autoreleasepool(invoking: { views.allObjects.isEmpty }) {
                            return "released at \(ContinuousClock.now - start)"
                        }
                        do {
                            try await Task.sleep(for: .milliseconds(20))
                        } catch {
                            return "release observation cancelled: \(error)"
                        }
                    }
                    return autoreleasepool { views.allObjects.isEmpty }
                        ? "released at \(ContinuousClock.now - start)" : "alive at 30 s"
                }
                lines += await Self.readinessTimeoutViewDiagnostics(views)
                lines += await Self.recentWebKitLogDiagnostics()
                lines.append(await lateRelease.value)
            }
            print(lines.map { "[Washi-cfm] \($0)" }.joined(separator: "\n"))
        }
        XCTAssertTrue(releasedWithinTenSeconds, "期限切れの JS 待機が WebView を保持している")
    }

    func testResizeSnapshotHoldProbe() {
        // Washi-cfm: 私的 API はテストの診断だけで使い、製品コードでは使わない。
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selector = NSSelectorFromString("_holdResizeSnapshotWithReason:")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        guard window.responds(to: selector) else {
            print("[Washi-cfm] resize-snapshot hold: unavailable (\(osVersion))")
            return
        }
        if let result = window.perform(selector, with: "washi-probe" as NSString) {
            print("[Washi-cfm] resize-snapshot hold: non-nil (\(osVersion))")
            let object = result.takeUnretainedValue()
            let releaseHold = unsafeBitCast(object, to: (@convention(block) () -> Void).self)
            releaseHold()
        } else {
            print("[Washi-cfm] resize-snapshot hold: nil (\(osVersion))")
        }
    }

    // Washi-cfm: 強参照は JS の送信中だけに限定し、応答待ちや解放観測へ持ち越さない。
    private static func readinessTimeoutViewDiagnostics(_ views: NSHashTable<WKWebView>) async
        -> [String] {
        var attachment: String?
        let replied: Bool? = await waitForOffscreenResult(timeout: .seconds(1)) { completion in
            autoreleasepool {
                guard let view = views.allObjects.first else {
                    completion(false)
                    return
                }
                attachment = "view.window == nil: \(view.window == nil); view.superview == nil: \(view.superview == nil)"
                view.evaluateJavaScript("1") { _, _ in completion(true) }
            }
        }
        guard let attachment else {
            return ["WebView released before liveness probe"]
        }
        return [attachment, "WebView liveness: \(replied == true ? "replied" : "no reply")"]
    }

    // Washi-cfm: 失敗時だけログを集める。読み取りでメインアクターや子プロセスを塞がない。
    private static func recentWebKitLogDiagnostics() async -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "60s", "--style", "compact", "--predicate",
            "processID == \(getpid()) AND subsystem == \"com.apple.WebKit\"",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ["WebKit log: launch failed: \(error)"]
        }
        let result: Result<(status: Int32, output: String), any Error>? =
            await waitForOffscreenResult(timeout: .seconds(10)) { completion in
                DispatchQueue.global(qos: .utility).async {
                    defer { try? pipe.fileHandleForReading.close() }
                    do {
                        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                        process.waitUntilExit()
                        let output = String(decoding: data, as: UTF8.self)
                        let status = process.terminationStatus
                        Task { @MainActor in completion(.success((status, output))) }
                    } catch {
                        Task { @MainActor in completion(.failure(error)) }
                    }
                }
            }
        guard let result else {
            if process.isRunning { process.terminate() }
            return ["WebKit log: no completion within 10 s (or cancelled); termination requested"]
        }
        switch result {
        case let .failure(error):
            if process.isRunning { process.terminate() }
            return ["WebKit log: read failed: \(error)"]
        case let .success((status, output)):
            var lines = ["WebKit log (last 60 s, at most 150 matching lines):"]
            if status != 0 {
                let reason = output.split(whereSeparator: \.isNewline).first ?? "no output"
                lines.append("log show exited with status \(status): \(reason)")
            }
            let pattern = "resize snapshot|WebPageProxy::close|WebPageProxy::destructor|nresponsive|isViewVisible|ProcessThrottler::setThrottleState"
            let matches = output.split(whereSeparator: \.isNewline).lazy.filter {
                $0.range(of: pattern, options: .regularExpression) != nil
            }.prefix(150)
            lines += matches.isEmpty ? ["no matching lines"] : matches.map(String.init)
            return lines
        }
    }

    private func assertRasterizedPage(publication: EPUBPublication,
                                      viewport: CGSize,
                                      deviceViewportSize: CGSize? = nil) async throws {
        let rasterizer = EPUBPageRasterizer(publication: publication)
        defer { rasterizer.invalidate() }
        let race = RenderRace()
        let renderTask = Task(priority: .userInitiated) { @MainActor in
            do {
                let image: CGImage
                if let deviceViewportSize {
                    image = try await rasterizer.renderPage(
                        atSpineIndex: 0,
                        deviceViewportSize: deviceViewportSize,
                        maxPixelSize: 300)
                } else {
                    image = try await rasterizer.renderPage(
                        atSpineIndex: 0, maxPixelSize: 300)
                }
                race.finish(with: .image(image))
            } catch {
                race.finish(with: .error(error))
            }
        }
        let watchdogTask = Task(priority: .userInitiated) { @MainActor in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            race.finish(with: .timedOut)
        }

        let outcome = await race.wait()
        renderTask.cancel()
        watchdogTask.cancel()
        let image: CGImage
        switch outcome {
        case let .image(renderedImage):
            image = renderedImage
        case let .error(error):
            throw error
        case .timedOut:
            XCTFail("renderPage did not return")
            return
        }

        let longEdge = max(image.width, image.height)
        XCTAssertEqual(longEdge, 300, accuracy: 2)
        let expectedAspectRatio = viewport.width / viewport.height
        let actualAspectRatio = CGFloat(image.width) / CGFloat(image.height)
        XCTAssertEqual(actualAspectRatio, expectedAspectRatio, accuracy: 0.02)
        XCTAssertTrue(Self.containsNonBlackPixel(image),
                      "ラスタライズ結果が全面黒ではないこと")
    }

    /// 8x8 へ縮小して複数地点を読み、全画素が黒の画像を検出する。
    private static func containsNonBlackPixel(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return false }
        return stride(from: 0, to: pixels.count, by: 4).contains { offset in
            pixels[offset] > 8 || pixels[offset + 1] > 8 || pixels[offset + 2] > 8
        }
    }

    private static func complexFixedLayoutEntries() -> [(name: String, data: Data)] {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:rasterizer-complex</dc:identifier>
                <dc:title>Complex fixed-layout page</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
                <meta property="rendition:layout">pre-paginated</meta>
              </metadata>
              <manifest>
                <item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head>
                <title>複雑固定ページ</title>
                <meta name="viewport" content="width=600, height=800"/>
                <style>html,body{margin:0;width:600px;height:800px;background:#fff}
                p{margin:48px;font-size:42px;color:#111}</style>
              </head>
              <body>
                <p>固定レイアウトの本文</p>
                <svg xmlns="http://www.w3.org/2000/svg" width="360" height="240"
                     viewBox="0 0 360 240">
                  <rect x="20" y="20" width="320" height="200" fill="#2878d0"/>
                </svg>
              </body>
            </html>
            """
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/page.xhtml", Data(xhtml.utf8)),
        ]
    }

    private static func deviceSizedFixedLayoutEntries()
        -> [(name: String, data: Data)] {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:rasterizer-device</dc:identifier>
                <dc:title>Device viewport</dc:title><dc:language>en</dc:language>
                <meta property="rendition:layout">pre-paginated</meta>
              </metadata>
              <manifest><item id="page" href="page.xhtml"
                media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head>
              <meta name="viewport"
                    content="width=device-width,height=device-height,initial-scale=1"/>
              <style>html,body{margin:0;width:100%;height:100%;background:#fff}</style>
            </head><body><div style="width:100%;height:100%;background:#2878d0"></div>
            </body></html>
            """
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/page.xhtml", Data(xhtml.utf8)),
        ]
    }
}

/// 描画後に残ったポリシーへ委譲して判定だけ記録する。デリゲート不在なら、
/// WebKit の既定どおり許可し、制限が失われたことをテストで検出する。
@MainActor
private final class LateNavigationPolicyProbe: NSObject, WKNavigationDelegate {
    private let forwarding: NavigationWaiter?
    private let checked: XCTestExpectation
    private(set) var policy: WKNavigationActionPolicy?

    init(forwarding: NavigationWaiter?, checked: XCTestExpectation) {
        self.forwarding = forwarding
        self.checked = checked
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let decision = await forwarding?.webView(
            webView, decidePolicyFor: navigationAction, preferences: preferences)
            ?? (.allow, preferences)
        if navigationAction.request.url?.absoluteString == "about:blank" {
            policy = decision.0
            checked.fulfill()
        }
        return decision
    }
}

@MainActor
private final class RenderRace {
    enum Outcome {
        case image(CGImage)
        case error(any Error)
        case timedOut
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(with outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
