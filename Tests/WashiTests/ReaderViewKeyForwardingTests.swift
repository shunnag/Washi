import AppKit
import WebKit
import XCTest
@testable import Washi

// EPUBReaderView 自身が受けた keyDown の転送と、WebKit から戻った未処理キーの
// responder チェーンへの受け渡し。ウインドウのキー監視による転送は
// NativeKeyRoutingTests、公開 API で組んだ EPUBKeyEvent の配送は
// WashiPublicAPITests/EPUBKeyEventTests を参照。方針を返す delegate の記録には
// EPUBReaderViewRegressionTests.swift の ReaderViewDelegateSpy を使う

@MainActor
private final class KeyDownResponderSpy: NSResponder {
    var events: [NSEvent] = []

    override func keyDown(with event: NSEvent) {
        events.append(event)
    }
}

@MainActor
final class ReaderViewKeyForwardingTests: XCTestCase {
    /// cooViewer-oxr.80: コンテナ自身が keyDown を受けても、host 優先設定なら
    /// DOM 往復なしで didReceiveKey へ配送する。
    func testReaderViewKeyDownForwardsWhenKeyboardNavigationDisabled() throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        var settings = view.settings
        settings.handlesKeyboardNavigation = false
        view.settings = settings
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "X", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7))

        view.keyDown(with: event)

        XCTAssertEqual(delegate.keys.count, 1)
        XCTAssertEqual(delegate.keys.first?.key, "x")
        XCTAssertEqual(delegate.keys.first?.shift, true)
    }

    /// Washi #3(コメント): host 優先設定でも、ホストが扱わなかったキーは
    /// responder チェーンへ流す。既定(true)では従来どおりここで止まる。
    func testUnconsumedForwardedKeyReachesNextResponder() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let responder = KeyDownResponderSpy()
        view.nextResponder = responder
        defer { view.nextResponder = nil }
        var settings = view.settings
        settings.handlesKeyboardNavigation = false
        view.settings = settings
        func event(_ characters: String, _ keyCode: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 1, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        }

        // 既定: 配送だけで上位へは流さない(1.16.x までと同じ)。
        let consumed = try event("x", 7)
        view.keyDown(with: consumed)
        XCTAssertEqual(delegate.keys.count, 1)
        XCTAssertEqual(delegate.consumeQuery.count, 1)
        XCTAssertTrue(responder.events.isEmpty)

        // false を返したキーだけ、元の NSEvent のまま上位へ渡る。
        delegate.onShouldConsumeKey = { $0.key != "x" ? false : true }
        for (characters, keyCode) in [("-", UInt16(27)), ("\u{1b}", 53), ("+", 24)] {
            let unhandled = try event(characters, keyCode)
            view.keyDown(with: unhandled)
            XCTAssertTrue(responder.events.last === unhandled)
        }
        XCTAssertEqual(responder.events.count, 3)
        XCTAssertEqual(delegate.keys.count, 4)
        XCTAssertEqual(delegate.consumeQuery.count, 4)
        // 判定は配送済みのキーについて行う。
        XCTAssertEqual(delegate.keys.map(\.key), delegate.consumeQuery.map(\.key))
    }

    /// 既定実装(shouldConsumeKey 未実装)は 1.16.x と同じく握り潰す。
    func testDefaultDelegateStillConsumesForwardedKeys() throws {
        final class KeyOnlyDelegate: EPUBReaderViewDelegate {
            var keys: [EPUBKeyEvent] = []
            func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
                keys.append(event)
            }
        }
        let view = EPUBReaderView(frame: .zero)
        let delegate = KeyOnlyDelegate()
        view.delegate = delegate
        let responder = KeyDownResponderSpy()
        view.nextResponder = responder
        defer { view.nextResponder = nil }
        var settings = view.settings
        settings.handlesKeyboardNavigation = false
        view.settings = settings
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "-", charactersIgnoringModifiers: "-",
            isARepeat: false, keyCode: 27))

        view.keyDown(with: event)

        XCTAssertEqual(delegate.keys.count, 1)
        XCTAssertTrue(responder.events.isEmpty)
    }

    /// Washi #3: WebKit の未処理キー返却を同期的に再現する。
    /// 再入を上位へ一度だけ通し、次のキーでは転送が再び有効になる。
    func testUnhandledKeyReentryForwardsOnceAndResetsForNextEvent() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let responder = KeyDownResponderSpy()
        view.nextResponder = responder
        defer { view.nextResponder = nil }
        var forwardCount = 0

        for (characters, keyCode) in [("-", UInt16(27)), ("\u{1b}", 53), ("+", 24)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 1, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            let count = responder.events.count
            view.routeKeyDown(with: event) { forwarded in
                forwardCount += 1
                XCTAssertTrue(forwarded === event)
                view.routeKeyDown(with: forwarded) { _ in
                    XCTFail("An unhandled key must not be sent back to WebKit")
                }
            }
            XCTAssertEqual(responder.events.count, count + 1)
            XCTAssertTrue(responder.events.last === event)
        }
        XCTAssertEqual(forwardCount, 3)
        XCTAssertTrue(delegate.keys.isEmpty)
    }

    /// WebKit から返るまでに設定が変わっても、再入を delegate へ重複配送しない。
    func testKeyReentryDoesNotRedispatchAfterKeyboardSettingChanges() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let responder = KeyDownResponderSpy()
        view.nextResponder = responder
        defer { view.nextResponder = nil }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "-", charactersIgnoringModifiers: "-",
            isARepeat: false, keyCode: 27))

        view.routeKeyDown(with: event) { forwarded in
            view.settings.handlesKeyboardNavigation = false
            view.keyDown(with: forwarded)
        }
        XCTAssertEqual(responder.events.count, 1)
        XCTAssertTrue(delegate.keys.isEmpty)

        view.keyDown(with: event)
        XCTAssertEqual(delegate.keys.count, 1)
    }

    func testKeyDownBeforeLoadingPublicationReachesNextResponder() throws {
        let view = EPUBReaderView(frame: .zero)
        let responder = KeyDownResponderSpy()
        view.nextResponder = responder
        defer { view.nextResponder = nil }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "-", charactersIgnoringModifiers: "-",
            isARepeat: false, keyCode: 27))

        view.keyDown(with: event)

        XCTAssertEqual(responder.events.count, 1)
        XCTAssertTrue(responder.events.first === event)
    }
}
