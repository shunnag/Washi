import AppKit
import XCTest
import Washi

@MainActor
private final class HostKeyBindings: EPUBReaderViewDelegate {
    enum Action: Equatable { case nextPage, previousPage }
    var action: Action?

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        guard event.key == " ", event.code == "Space",
              !event.option, !event.control, !event.command else {
            action = nil
            return
        }
        action = event.shift ? .previousPage : .nextPage
    }

    func readerView(_ view: EPUBReaderView, shouldConsumeKey event: EPUBKeyEvent) -> Bool {
        action != nil
    }
}

@MainActor
private final class KeyEventRecorder: EPUBReaderViewDelegate {
    var events: [EPUBKeyEvent] = []

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        events.append(event)
    }
}

@MainActor
final class EPUBKeyEventTests: XCTestCase {
    func testHostKeyBindingsCanBeTestedWithPubliclyConstructedEvents() {
        let view = EPUBReaderView(frame: .zero)
        let bindings = HostKeyBindings()
        // イベントの生成とデリゲートの直接呼び出しだけで、利用側の分岐を検証する。
        let cases: [(EPUBKeyEvent, HostKeyBindings.Action?)] = [
            (EPUBKeyEvent(key: " ", code: "Space"), .nextPage),
            (EPUBKeyEvent(key: " ", code: "Space", shift: true), .previousPage),
            (EPUBKeyEvent(key: " ", code: "Space", option: true), nil),
            (EPUBKeyEvent(key: " ", code: "Space", control: true), nil),
            (EPUBKeyEvent(key: " ", code: "Space", command: true), nil),
            (EPUBKeyEvent(key: "Escape", code: "Escape"), nil),
            (EPUBKeyEvent(key: " ", code: "Other"), nil),
            (EPUBKeyEvent(key: "Other", code: "Space"), nil),
        ]

        for (event, action) in cases {
            bindings.readerView(view, didReceiveKey: event)
            XCTAssertEqual(bindings.action, action, "\(event)")
            XCTAssertEqual(bindings.readerView(view, shouldConsumeKey: event), action != nil)
        }
    }

    func testPubliclyConstructedEventsMatchNativeDelivery() throws {
        let view = EPUBReaderView(frame: .zero)
        view.settings.handlesKeyboardNavigation = false
        let recorder = KeyEventRecorder()
        view.delegate = recorder
        let modifiers: [NSEvent.ModifierFlags] = [.shift, .option, .control, .command]

        // 各修飾キーの独立性と、既存のネイティブ配送が同じ値を渡すことを確認する。
        for mask in 0..<16 {
            var flags: NSEvent.ModifierFlags = []
            for (index, modifier) in modifiers.enumerated() where mask & (1 << index) != 0 {
                flags.insert(modifier)
            }
            let native = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
            let expected = EPUBKeyEvent(
                key: " ", code: "Space", shift: mask & 1 != 0,
                option: mask & 2 != 0, control: mask & 4 != 0, command: mask & 8 != 0)

            view.keyDown(with: native)

            XCTAssertEqual(recorder.events.count, mask + 1)
            let received = try XCTUnwrap(recorder.events.last)
            XCTAssertEqual(received, expected)
            XCTAssertEqual(received.shift, flags.contains(.shift))
            XCTAssertEqual(received.option, flags.contains(.option))
            XCTAssertEqual(received.control, flags.contains(.control))
            XCTAssertEqual(received.command, flags.contains(.command))
        }
    }
}
