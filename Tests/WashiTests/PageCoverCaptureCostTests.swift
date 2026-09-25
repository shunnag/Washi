import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class PageCoverCaptureMoveDelegate: EPUBReaderViewDelegate {
    var moves = 0
    var failure: (any Error)?

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moves += 1
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failure = error
    }
}

@MainActor
final class PageCoverCaptureCostTests: XCTestCase {
    func testMeasurePageCoverCaptureCost() async throws {
        guard ProcessInfo.processInfo.environment["WASHI_MEASURE_PAGE_COVER"] == "1" else {
            throw XCTSkip("WASHI_MEASURE_PAGE_COVER=1 のときだけ撮影コストを計測します")
        }

        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main, "計測には表示可能な画面が必要です")
        let size = screen.backingScaleFactor < 2
            ? NSSize(width: 2880, height: 1800)
            : NSSize(width: 1440, height: 900)
        let books = [
            (name: "reflowable", entries: EPUBFixtures.verticalNovelEntries()),
            (name: "fxl-detail", entries: try detailedFXLEntries()),
        ]

        for book in books {
            try await measureBook(book.name, entries: book.entries, size: size, screen: screen)
        }
    }

    private func detailedFXLEntries() throws -> [(name: String, data: Data)] {
        var entries = EPUBFixtures.fxlComicEntries()
        for index in entries.indices where entries[index].name.hasSuffix(".png") {
            entries[index].data = try randomRGBPNG(seed: UInt64(index + 1))
        }
        return entries
    }

    private func randomRGBPNG(seed: UInt64) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 1920,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 1200 * 3, bitsPerPixel: 24))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        var state = seed
        // 毎回同じ画素を使い、単色画像の圧縮・描画の軽さを避ける。
        for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[offset] = UInt8(truncatingIfNeeded: state >> 56)
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeWindow(containing view: NSView, on screen: NSScreen) -> NSWindow {
        let visible = screen.visibleFrame
        let size = NSSize(width: min(view.frame.width, visible.width),
                          height: min(view.frame.height, visible.height))
        let rect = NSRect(x: visible.midX - size.width / 2,
                          y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        // 小さい画面でもウインドウを画面内に収め、撮影するビューの寸法は保つ。
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = []
        container.addSubview(view)
        window.contentView = container
        window.setFrame(rect, display: false)
        window.orderFrontRegardless()
        return window
    }

    private func webView(of view: EPUBReaderView) throws -> WKWebView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
    }

    private func waitUntil(
        timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func measureBook(_ name: String, entries: [(name: String, data: Data)],
                             size: NSSize, screen: NSScreen) async throws {
        // PNG を再圧縮せず格納し、本の生成を撮影時間に含めない。
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 0),
            displayURL: URL(fileURLWithPath: "/tmp/washi-page-cover-cost-\(name).epub"))
        let view = EPUBReaderView(frame: NSRect(origin: .zero, size: size))
        view.accessibilityReduceMotionOverride = false
        view.settings.pageTurnStyle = .none
        view.isWindowOnScreenOverride = true
        let window = makeWindow(containing: view, on: screen)
        defer {
            window.contentView = nil
            window.close()
            view.unload()
        }

        let delegate = PageCoverCaptureMoveDelegate()
        view.delegate = delegate
        view.load(publication: publication)
        view.layoutSubtreeIfNeeded()
        let web = try webView(of: view)
        let shown = try await waitUntil {
            delegate.failure != nil || (delegate.moves > 0 && web.alphaValue == 1)
        }
        if let failure = delegate.failure { throw failure }
        guard shown else {
            XCTFail("\(name): 10 秒以内にページが画面上へ表示されませんでした")
            return
        }
        // 裏で動くページ数の実測が撮影コストに混ざらないよう止める。
        view.cancelPageCensus()

        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        for _ in 0..<3 {
            _ = try await web.takeSnapshot(configuration: configuration)
        }

        var samples: [Double] = []
        samples.reserveCapacity(20)
        var lastImage: NSImage?
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let image = try await web.takeSnapshot(configuration: configuration)
            let elapsed = start.duration(to: ContinuousClock.now).components
            samples.append(Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
            lastImage = image
        }

        let image = try XCTUnwrap(
            lastImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sorted = samples.sorted()
        // 20 件の中央値は中央 2 件の平均、p95 は小さい方から 19 番目。
        let statistics = String(
            format: "min=%.1f median=%.1f p95=%.1f max=%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            sorted[0], (sorted[9] + sorted[10]) / 2, sorted[18], sorted[19])
        let screenScales = NSScreen.screens.map { String(describing: $0.backingScaleFactor) }
            .joined(separator: ",")
        print(
            "page-cover-cost book=\(name)"
                + " viewPt=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
                + " windowScale=\(window.backingScaleFactor) screens=[\(screenScales)]"
                + " image=\(image.width)x\(image.height) \(statistics)"
                + " thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"
                + " occludedVisible=\(window.occlusionState.contains(.visible))")
    }
}
