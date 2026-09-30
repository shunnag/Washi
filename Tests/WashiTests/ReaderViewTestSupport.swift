import AppKit
import WebKit
import XCTest
@testable import Washi

// EPUBReaderView や WKWebView を実際に動かすテストで繰り返していた道具立て。
// 画面外ウインドウ・条件待ち・WebView の取り出し・後始末・WebKit 不在時の skip を
// 1 か所に置き、各テストは自分の待ち時間や後始末の種類を明示して呼ぶ。

/// 画面外(-20_000, -20_000)に置く枠なしウインドウを作り、`view` を contentView にする。
/// 大きさは `view.frame.size` に合わせる。`ignoresMouseEvents: false` が要るのは、
/// テストが NSEvent(クリック・ホイール・キー)をこのウインドウへ送るときだけ
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

/// 次のページ割りの通知(`delegate.moveCount > moves`)と表示の復帰(`web.alphaValue == 1`)
/// を待つ。通知が来なければ WebKit が使えないものとして CI では失敗、ローカルでは skip する
@MainActor
func waitUntilShown(_ web: WKWebView, _ delegate: ReaderObservationSpy, after moves: Int,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    guard await waitUntil(timeout: .seconds(8), poll: .milliseconds(10), { delegate.moveCount > moves }) else {
        return try skipOrFailIfWebKitUnavailable(file: file, line: line)
    }
    let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(10)) { web.alphaValue == 1 }
    XCTAssertTrue(shown, "表示が戻らない", file: file, line: line)
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

/// 観測だけの delegate 呼び出しを記録する。方針を返すメソッド
/// (shouldConsumeKey・didClick など)は実装しない: 実装するとリーダーの挙動が変わる
@MainActor
final class ReaderObservationSpy: EPUBReaderViewDelegate {
    /// didMoveTo で受け取った locator(到着順)
    private(set) var moves: [EPUBLocator] = []
    var moveCount: Int { moves.count }
    private(set) var failures: [any Error] = []
    /// 失敗を受けた時点の currentLocator
    private(set) var failureLocators: [EPUBLocator] = []
    private(set) var edges: [Bool] = []
    private(set) var printPages: [String?] = []
    private(set) var playingChanges: [Bool] = []
    private(set) var finishCount = 0
    /// 履歴が変わるたびの canGoBack
    private(set) var canGoBackChanges: [Bool] = []
    private(set) var censusUpdateCount = 0
    /// 失敗・再生状態・終了の前後関係("failure" / "playing:<Bool>" / "finished")
    private(set) var events: [String] = []
    var onMove: ((EPUBReaderView) -> Void)?
    var onFailure: ((EPUBReaderView) -> Void)?
    var onHistoryChanged: ((EPUBReaderView) -> Void)?

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moves.append(locator)
        onMove?(view)
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
        failureLocators.append(view.currentLocator)
        events.append("failure")
        onFailure?(view)
    }

    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {
        edges.append(forward)
    }

    func readerView(_ view: EPUBReaderView, didChangePrintPage label: String?) {
        printPages.append(label)
    }

    func readerView(_ view: EPUBReaderView, isPlayingMediaOverlayDidChange playing: Bool) {
        playingChanges.append(playing)
        events.append("playing:\(playing)")
    }

    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView) {
        finishCount += 1
        events.append("finished")
    }

    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {
        canGoBackChanges.append(view.canGoBack)
        onHistoryChanged?(view)
    }

    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        censusUpdateCount += 1
    }
}

/// 方針を返すメソッド(shouldConsumeKey・didReceiveDroppedFileURL)も実装する
/// delegate の記録係。実装するとリーダーの挙動が変わる(転送したキーの消費・ドロップの
/// 受理)ので、観測だけで足りるテストは ReaderObservationSpy を使う
@MainActor
final class ReaderViewDelegateSpy: EPUBReaderViewDelegate {
    var keys: [EPUBKeyEvent] = []
    var consumeQuery: [EPUBKeyEvent] = []
    var onShouldConsumeKey: ((EPUBKeyEvent) -> Bool)?
    var droppedURLs: [URL] = []
    var failures: [any Error] = []
    var censusUpdateCount = 0
    var moveCount = 0

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moveCount += 1
    }

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        keys.append(event)
    }

    func readerView(_ view: EPUBReaderView,
                    shouldConsumeKey event: EPUBKeyEvent) -> Bool {
        consumeQuery.append(event)
        return onShouldConsumeKey?(event) ?? true
    }

    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool {
        droppedURLs.append(url)
        return true
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
    }

    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        censusUpdateCount += 1
    }
}
