import AppKit
import WebKit
import XCTest
@testable import Washi

// spine 遷移の見え方の取り決め:
// 1. 読み込みの開始では透明にしない(前のページはコミットまで見えている)
// 2. 描画フレームの待ちは必ず打ち切られ、取り消しにも即座に応じる
// 3. 控えのカバーは条件が一致したときだけ、撮った矩形に貼られ、表示が戻ると畳まれる
// 4. 見た目の変更と画面への復帰で控えを撮り直す
// 5. 続けて移動したときは、最初に重ねた前のページの控えを最新の項目の表示まで使う
//
// 検証は SpineTransitionVisibilityTests(1・2)、PageCoverRetakeTests(3・4)、
// ChainedMovePageCoverTests(5)に分け、共通の道具立てをここに置く。

extension XCTestCase {
    /// 2 番目の項目(ch2)を text/html と宣言し、描画可能な fallback の無い項目にする
    @MainActor
    func makePublicationWithUnrenderableSecondItem() throws -> EPUBPublication {
        var entries = EPUBFixtures.verticalNovelEntries()
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: #"<item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>"#,
            with: #"<item id="ch2" href="text/ch2.xhtml" media-type="text/html"/>"#)
        let publication = try EPUBFixtures.publication(entries, name: "washi-unrenderable-second")
        XCTAssertFalse(publication.canRenderSpineResource(publication.readingOrder[1]))
        return publication
    }

    /// 本を開き、最初の表示が戻るまで待つ。WebKit が使えなければ skip する
    @MainActor
    func openAndSettle(_ view: EPUBReaderView, _ publication: EPUBPublication,
                       delegate: ReaderObservationSpy) async throws {
        view.delegate = delegate
        view.load(publication: publication)
        guard await waitUntil(timeout: .seconds(8), poll: .milliseconds(5), { delegate.moveCount > 0 }) else {
            return try skipOrFailIfWebKitUnavailable()
        }
        let shown = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) { (try? view.firstWebView().alphaValue) == 1 }
        XCTAssertTrue(shown)
    }

    @MainActor
    func cover(for view: EPUBReaderView, rect: NSRect,
               spineIndex: Int = 0, pageInItem: Int = 0)
        -> EPUBReaderView.PrefetchedPageCover
    {
        EPUBReaderView.PrefetchedPageCover(
            image: NSImage(size: rect.size), rect: rect,
            backingScale: view.window?.backingScaleFactor ?? 2,
            spineIndex: spineIndex, pageInItem: pageInItem,
            size: view.bounds.size, fontScale: view.settings.fontScale)
    }

    @MainActor
    func makeCoverReader(theme: EPUBReaderTheme = .light,
                         pageTurnStyle: EPUBPageTurnStyle = .none)
        -> (view: EPUBReaderView, window: NSWindow)
    {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.settings.theme = theme
        view.settings.pageTurnStyle = pageTurnStyle
        view.accessibilityReduceMotionOverride = false
        view.accessibilityIncreaseContrastOverride = false
        view.accessibilityDifferentiateWithoutColorOverride = false
        view.isWindowOnScreenOverride = true
        // 画面外でも、見た目を変えた JS の実行後に撮影する順序を保つ
        view.animationFrameWait = {
            await EPUBReaderView.waitForWashiScript("return true;", in: $0)
        }
        return (view, makeOffscreenWindow(containing: view))
    }

    /// 控えの引き継ぎを確かめるリーダー。画面外扱いに固定して撮影を止め、控えは
    /// 差し替え口で置く。アクセシビリティの設定も固定し、OS の設定に依存させない
    @MainActor
    func makeChainReader(reduceMotion: Bool = false,
                         pageTurnStyle: EPUBPageTurnStyle = .none)
        -> (view: EPUBReaderView, window: NSWindow)
    {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.settings.pageTurnStyle = pageTurnStyle
        view.accessibilityReduceMotionOverride = reduceMotion
        view.accessibilityIncreaseContrastOverride = false
        view.accessibilityDifferentiateWithoutColorOverride = false
        view.isWindowOnScreenOverride = false
        return (view, makeOffscreenWindow(containing: view))
    }

    @MainActor
    func waitForCover(
        _ view: EPUBReaderView, replacing old: NSImage? = nil,
        message: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> EPUBReaderView.PrefetchedPageCover {
        let ready = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            guard let cover = view.pageCover.prefetchedPageCover else { return false }
            return cover.image !== old
        }
        return try XCTUnwrap(
            ready ? view.pageCover.prefetchedPageCover : nil,
            message ?? (old == nil
                ? "初回の控え A を撮影できない。画面外のウインドウで撮影できる前提を確認する"
                : "控えの撮り直しが時間切れになった"),
            file: file, line: line)
    }

    /// スクロール補正の遅配を待ち、移動回数と控えの同一性が 300 ms 続けて安定したら返す。
    @MainActor
    func settledCover(_ view: EPUBReaderView, delegate: ReaderObservationSpy) async throws
        -> EPUBReaderView.PrefetchedPageCover
    {
        var current = try await waitForCover(view)
        var moves = delegate.moveCount
        var stableSince = ContinuousClock.now
        let settled = await waitUntil(timeout: .seconds(8), poll: .milliseconds(5)) {
            guard let cover = view.pageCover.prefetchedPageCover else {
                stableSince = .now
                return false
            }
            if delegate.moveCount != moves || cover.image !== current.image {
                moves = delegate.moveCount
                current = cover
                stableSince = .now
            }
            return ContinuousClock.now - stableSince >= .milliseconds(300)
        }
        return try XCTUnwrap(settled ? view.pageCover.prefetchedPageCover : nil,
                             "移動回数と控えが安定するまでの待ちが時間切れになった")
    }

    /// sRGB の 16×16 画素に縮小し、本文より広い地色の明るさを調べる
    @MainActor
    func meanLuminance(_ image: NSImage) -> Double {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8,
                bytesPerRow: 16 * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else {
            XCTFail("控えの輝度を調べるための画像と描画領域を用意できない")
            return .nan
        }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let total = stride(from: 0, to: 16 * 16 * 4, by: 4).reduce(0.0) { sum, offset in
            sum + 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
        }
        return total / (16 * 16 * 255)
    }
}
