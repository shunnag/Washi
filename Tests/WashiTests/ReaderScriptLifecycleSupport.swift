import AppKit
import WebKit
import XCTest
@testable import Washi

// ReaderScripts のライフサイクル検証(ReaderScriptsRenderingLifecycleTests・
// ReaderScriptClickDispatchTests・ReaderScriptMessageEndToEndTests)が共有する、
// "washi" メッセージの記録係と ReaderScriptHarness の拡張

@MainActor
final class RenderingLifecycleMessageRecorder: NSObject, WKScriptMessageHandler {
    private(set) var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            messages.append(body)
        }
    }

    func reset() {
        messages.removeAll()
    }

    func count(type: String) -> Int {
        messages.count { $0["type"] as? String == type }
    }

    func compactMap<T>(_ transform: ([String: Any]) -> T?) -> [T] {
        messages.compactMap(transform)
    }

    func first(type: String) -> [String: Any]? {
        messages.first { $0["type"] as? String == type }
    }
}

extension ReaderScriptHarness {
    /// "washi" メッセージを RenderingLifecycleMessageRecorder で記録するハーネスを組む
    static func renderingLifecycle(bodyHTML: String) throws -> ReaderScriptHarness {
        try ReaderScriptHarness(
            bodyHTML: bodyHTML,
            messageHandler: (name: "washi", handler: RenderingLifecycleMessageRecorder()))
    }

    /// `renderingLifecycle(bodyHTML:)` で登録した記録係
    var messages: RenderingLifecycleMessageRecorder {
        guard let recorder = scriptMessageHandler as? RenderingLifecycleMessageRecorder else {
            preconditionFailure("renderingLifecycle(bodyHTML:) で組んだハーネスだけが messages を持つ")
        }
        return recorder
    }

    /// ライフサイクル検証用の setup(タップ保留と doubleClickDelayMS を含む)。
    /// `documentToken` を渡すと JS が post する各メッセージの `token` に載る
    func setupLifecycle(spread: Bool = false, keysEnabled: Bool = false,
                                    fixedLayout: Bool = false,
                                    deferTaps: Bool = false,
                                    documentToken: String? = nil) async throws {
        let token = documentToken.map { "documentToken:'\($0)'," } ?? ""
        let _: Int = try await evaluate("""
            const result = __washi.setup({width:640,height:400,gap:24,
                spread:\(spread),gutter:48,fixedLayout:\(fixedLayout),
                keysEnabled:\(keysEnabled),deferTaps:\(deferTaps),\(token)
                doubleClickDelayMS:250,userCSS:''});
            return result.pageCount;
            """)
    }

    /// WebKit のナビゲーションが完了しなければ、既存の慣例どおり CI では失敗・
    /// ローカルでは skip にして打ち切る
    func loadForLifecycleTest(file: StaticString = #filePath,
                                          line: UInt = #line) async throws {
        do {
            try await load()
        } catch {
            try failOrSkipWebKitTest("WKWebView の読み込みが完了しませんでした: \(error)",
                                     file: file, line: line)
            throw error
        }
    }

    func settleMessages() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    func waitForMessage(type: String) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) > 0 { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func waitForMessageCount(type: String, count: Int) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) >= count { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
