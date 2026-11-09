import WebKit
import XCTest
@testable import Washi

@MainActor
final class OffscreenWebViewConfigurationTests: XCTestCase {
    /// cooViewer-oxr.75/88: 共通構成は著者スクリプト設定を反映しつつ、
    /// 不可視ビューでの全メディア autoplay を常に抑止する。
    func testOffscreenConfigurationRequiresUserActionForAllMedia() {
        let disabled = EPUBOffscreenWebViewConfiguration.make(
            allowsScriptedContent: false)
        let enabled = EPUBOffscreenWebViewConfiguration.make(
            allowsScriptedContent: true)

        XCTAssertEqual(disabled.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertEqual(enabled.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertFalse(
            disabled.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(enabled.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(disabled.suppressesIncrementalRendering)
        XCTAssertTrue(enabled.suppressesIncrementalRendering)
    }

    /// Washi-hgd: 表示・非表示とも autoplay を抑止し、本の状態は WebView ごとに分離する。
    func testReaderAndOffscreenConfigurationsShareHardening() throws {
        let publication = try EPUBFixtures.singleSpine(
            bodyHTML: "<p>和紙</p>", name: "washi-reader-offscreen-hardening")
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

    /// Washi-ec3: 画面上だけホストが autoplay を許可でき、切替で構成を作り直す。
    func testMediaAutoplayOptInRebuildsVisibleWebViewWithoutRelaxingOffscreen() throws {
        let publication = try EPUBFixtures.singleSpine(
            bodyHTML: "<video autoplay muted loop src=\"movie.mp4\"></video>",
            name: "washi-media-autoplay-opt-in")
        let view = EPUBReaderView(frame: .zero)
        defer { view.unload() }
        XCTAssertFalse(view.settings.allowsMediaAutoplay)
        view.spineLoadHandler = { _ in try? makeNavigationTokenForTest() }
        view.load(publication: publication)
        let original = try XCTUnwrap(view.webView)
        XCTAssertEqual(original.configuration.mediaTypesRequiringUserActionForPlayback, .all)

        view.settings.allowsMediaAutoplay = true
        let rebuilt = try XCTUnwrap(view.webView)
        XCTAssertFalse(original === rebuilt)
        XCTAssertEqual(rebuilt.configuration.mediaTypesRequiringUserActionForPlayback, [])
        for scripts in [false, true] {
            let offscreen = EPUBOffscreenWebViewConfiguration.make(
                allowsScriptedContent: scripts)
            XCTAssertEqual(offscreen.mediaTypesRequiringUserActionForPlayback, .all)
        }
    }

    /// cooViewer-oxr.87: 著者スクリプト無効時には hardening script 自体を
    /// 構成へ追加せず、有効時だけ document-start へ登録する。
    func testWebRTCHardeningScriptOnlyInstalledForScriptedContent() throws {
        let disabled = EPUBOffscreenWebViewConfiguration.make(
            allowsScriptedContent: false)
        let disabledHardeningScripts = disabled.userContentController.userScripts
            .filter { $0.source.contains("RTCPeerConnectionIceEvent") }
        XCTAssertTrue(disabledHardeningScripts.isEmpty)

        let configuration = EPUBOffscreenWebViewConfiguration.make(
            allowsScriptedContent: true)
        let hardeningScripts = configuration.userContentController.userScripts
            .filter { $0.source.contains("RTCPeerConnectionIceEvent") }
        let hardeningScript = try XCTUnwrap(hardeningScripts.first)
        XCTAssertEqual(hardeningScripts.count, 1)
        XCTAssertEqual(hardeningScript.injectionTime, .atDocumentStart)
        XCTAssertFalse(hardeningScript.isForMainFrameOnly)
        for untouchedAPI in [
            "mediaDevices", "geolocation", "WebSocket", "EventSource",
            "fetch", "XMLHttpRequest"
        ] {
            XCTAssertFalse(hardeningScript.source.contains(untouchedAPI))
        }
    }

    /// cooViewer-oxr.87: PAGE world の document-start 注入が著者スクリプトより
    /// 先に WebRTC を塞ぎ、書き戻せない descriptor にする。
    func testScriptedContentPageWorldNeutersWebRTCAtDocumentStart() async throws {
        let configuration = EPUBOffscreenWebViewConfiguration.make(
            allowsScriptedContent: true)
        let body = """
            <script>
            window.__rtcTypesAtAuthorStart = [
                typeof RTCPeerConnection,
                typeof webkitRTCPeerConnection,
                typeof RTCDataChannel,
                typeof RTCSessionDescription,
                typeof RTCIceCandidate,
                typeof RTCPeerConnectionIceEvent
            ].join(',');
            </script>
            <p>WebRTC hardening</p>
            """
        let publication = try EPUBFixtures.singleSpine(bodyHTML: body,
            name: "washi-webrtc-hardening")
        let handler = EPUBSchemeHandler(publication: publication,
                                        allowsScripts: true)
        configuration.setURLSchemeHandler(
            handler, forURLScheme: EPUBSchemeHandler.scheme)

        let size = NSSize(width: 480, height: 320)
        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: size),
            configuration: configuration)
        let window = makeOffscreenWindow(containing: webView)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
        }

        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: entry))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        do {
            try await waiter.wait(timeout: .seconds(15))
        } catch {
            return try failOrSkipIfWebKitUnavailable()
        }

        let expected = Array(repeating: "undefined", count: 6).joined(separator: ",")
        let authorTypes = try await webView.callAsyncJavaScript(
            "return window.__rtcTypesAtAuthorStart;",
            in: nil,
            contentWorld: .page) as? String
        XCTAssertEqual(authorTypes, expected)

        let runtimeTypes = try await webView.callAsyncJavaScript(
            """
            return [
                typeof RTCPeerConnection,
                typeof webkitRTCPeerConnection,
                typeof RTCDataChannel,
                typeof RTCSessionDescription,
                typeof RTCIceCandidate,
                typeof RTCPeerConnectionIceEvent
            ].join(',');
            """,
            in: nil,
            contentWorld: .page) as? String
        XCTAssertEqual(runtimeTypes, expected)

        let descriptorsAreLocked = try await webView.callAsyncJavaScript(
            """
            const names = [
                'RTCPeerConnection', 'webkitRTCPeerConnection',
                'RTCDataChannel', 'RTCSessionDescription', 'RTCIceCandidate',
                'RTCPeerConnectionIceEvent'
            ];
            return [window, globalThis].every(target => names.every(name => {
                const descriptor = Object.getOwnPropertyDescriptor(target, name);
                return descriptor && descriptor.value === undefined
                    && descriptor.writable === false
                    && descriptor.configurable === false;
            }));
            """,
            in: nil,
            contentWorld: .page) as? Bool
        XCTAssertEqual(descriptorsAreLocked, true)
    }
}
