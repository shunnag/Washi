import AppKit
import WebKit
import XCTest
@testable import Washi

// setup JSON の見開き判定と、項目ごとの見開き余白の反映

@MainActor
final class ReaderViewSpreadSetupTests: XCTestCase {
    private func makePublication(
        spread: RenditionSpread, itemProperties: String
    ) throws -> EPUBPublication {
        var entries = EPUBFixtures.reflowSpreadEntries(
            renditionSpread: spread,
            bodyHTML: "<p>\(String(repeating: "本文。", count: 200))</p>")
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: #"<itemref idref="c"/>"#,
            with: #"<itemref idref="c" properties="\#(itemProperties)"/>"#)
        return try EPUBFixtures.publication(entries, name: "washi-reader-item-spread")
    }

    private func makeSpreadTransitionPublication() throws -> EPUBPublication {
        var entries = EPUBFixtures.reflowSpreadEntries(
            renditionSpread: .both,
            bodyHTML: "<p>first</p>")
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: #"<manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/></manifest>"#,
            with: #"<manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/></manifest>"#)
        entries = try EPUBFixtures.replacing(
            entries, in: "OEBPS/package.opf",
            of: #"<spine><itemref idref="c"/></spine>"#,
            with: #"<spine><itemref idref="c"/><itemref idref="c2" properties="rendition:spread-none"/></spine>"#)
        entries.append((
            "OEBPS/text/c2.xhtml",
            Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>second</body></html>".utf8)))
        return try EPUBFixtures.publication(entries, name: "washi-reader-spread-transition")
    }

    private func setupOptions(of view: EPUBReaderView) throws -> [String: Any] {
        let data = try XCTUnwrap(view.setupOptionsJSON().data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// cooViewer-oxr.27: Swift API の既定値と setup JSON の opt-in 配線を検証する。
    func testSetupOptionsPassesTapDeferralPreference() throws {
        var settings = EPUBReaderSettings()
        XCTAssertFalse(settings.defersTapsForDoubleClick)

        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings = settings
        var options = try setupOptions(of: view)
        XCTAssertEqual(options["deferTaps"] as? Bool, false)
        XCTAssertNil(options["doubleClickDelayMS"])

        settings.defersTapsForDoubleClick = true
        view.settings = settings
        options = try setupOptions(of: view)
        XCTAssertEqual(options["deferTaps"] as? Bool, true)
        XCTAssertGreaterThan(options["doubleClickDelayMS"] as? Double ?? 0, 0)
    }

    /// spreadInsets 適用後の狭い実幅ではなく、基準余白の幅でライブ側も
    /// census と同じ見開き判定をする
    func testSetupSpreadMatchesScreenMetricsAcrossMismatchWindow() throws {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(
            top: 24, left: 56, bottom: 24, right: 56)
        settings.spreadInsets = EPUBReaderInsets(
            top: 24, left: 100, bottom: 24, right: 100)

        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 812, height: 900))
        view.settings = settings
        for width in [CGFloat(812), 850, 899] {
            view.frame.size.width = width
            let options = try setupOptions(of: view)
            let liveSpread = try XCTUnwrap(options["spread"] as? Bool)
            let metrics = EPUBScreenMetrics(
                viewportSize: view.bounds.size, settings: settings)
            XCTAssertEqual(liveSpread, metrics.pagesPerScreen == 2,
                           "viewport width: \(width)")
        }
    }

    func testSetupSpreadHonorsPublicationRenditionSpread() throws {
        let bothView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 900))
        bothView.load(publication: try EPUBFixtures.reflowSpread(.both))
        XCTAssertEqual(try setupOptions(of: bothView)["spread"] as? Bool, true)

        let noneView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        noneView.load(publication: try EPUBFixtures.reflowSpread(.none))
        XCTAssertEqual(try setupOptions(of: noneView)["spread"] as? Bool, false)
    }

    /// cooViewer-oxr.51: 文書既定が見開きでも、現在 itemref の override が
    /// ライブ setup を単ページへ切り替える。
    func testSetupSpreadHonorsCurrentItemOverride() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        view.load(publication: try makePublication(
            spread: .both, itemProperties: "rendition:spread-none"))

        XCTAssertEqual(try setupOptions(of: view)["spread"] as? Bool, false)
        XCTAssertEqual(view.plannedPagesPerScreen, 1)
    }

    /// cooViewer-oxr.51: 単ページ override の spine を直接開く場合、旧項目の
    /// 見開き余白を WebView の初期フレームへ残さない。
    func testSpineTransitionUpdatesFrameForItemSpreadInsets() throws {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(
            top: 20, left: 20, bottom: 20, right: 20)
        settings.spreadInsets = EPUBReaderInsets(
            top: 20, left: 100, bottom: 20, right: 100)
        let publication = try makeSpreadTransitionPublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        view.settings = settings

        view.load(
            publication: publication,
            at: EPUBLocator(spineIndex: 1, progression: 0, idref: "c2"))

        let webView = try view.firstWebView()
        XCTAssertEqual(webView.frame.width, 1_160)
        XCTAssertEqual(try setupOptions(of: view)["spread"] as? Bool, false)
    }
}
