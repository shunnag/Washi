import AppKit
import WebKit
import XCTest
@testable import Washi

// EPUBReaderView や WKWebView を実際に動かすテストで繰り返していた道具立て。
// 画面外ウインドウ・条件待ち・WebView の取り出し・後始末・WebKit 不在時の skip を
// 1 か所に置き、各テストは自分の待ち時間や後始末の種類を明示して呼ぶ。

/// 画面外(-20_000, -20_000)に置く枠なしウインドウを作り、`view` を contentView にする。
/// 大きさは `view.frame.size` に合わせる。
@MainActor
func makeOffscreenWindow(containing view: NSView,
                         ignoresMouseEvents: Bool = true) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                            size: view.frame.size),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = ignoresMouseEvents
    window.contentView = view
    return window
}

/// 条件が満たされるまで MainActor を回して待つ(期限つき)。
/// 期限を過ぎたら最後にもう一度だけ条件を見て、その結果を返す。
@MainActor
func waitUntil(timeout: Duration, poll: Duration = .milliseconds(20),
               _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return condition()
}

extension EPUBReaderView {
    /// 表示用の WKWebView(直接の subview)を取り出す。無ければテスト失敗
    func firstWebView(file: StaticString = #filePath, line: UInt = #line) throws -> WKWebView {
        try XCTUnwrap(subviews.compactMap { $0 as? WKWebView }.first, file: file, line: line)
    }
}

/// `closeReader` でウインドウを畳む前にリーダーへ行う後始末
enum ReaderTeardown {
    /// 裏で動くページ数の実測だけ止める
    case cancelPageCensus
    /// 本を閉じる(実測の停止も含む)
    case unload
    /// リーダーには何もしない
    case none
}

/// リーダーの後始末をしてからウインドウから外し、閉じる。
/// `clearsDelegate` は後始末の後・ウインドウから外す前に delegate を nil にする
@MainActor
func closeReader(_ view: EPUBReaderView, in window: NSWindow,
                 teardown: ReaderTeardown, clearsDelegate: Bool = false) {
    switch teardown {
    case .cancelPageCensus: view.cancelPageCensus()
    case .unload: view.unload()
    case .none: break
    }
    if clearsDelegate { view.delegate = nil }
    window.contentView = nil
    window.close()
}

/// この環境で WKWebView のナビゲーションが動かなかったときの共通の打ち切り
/// (CI では失敗、ローカルでは skip)
func skipOrFailIfWebKitUnavailable(
    file: StaticString = #filePath, line: UInt = #line
) throws {
    try failOrSkipWebKitTest(
        "WKWebView navigation is unavailable in this sandbox", file: file, line: line)
}
