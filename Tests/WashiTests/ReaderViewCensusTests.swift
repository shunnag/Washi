import AppKit
import WebKit
import XCTest
@testable import Washi

// ページ数の実測(census)の取り込みと、通しページ番号と locator の相互変換。
// delegate の観測には ReaderViewTestSupport の ReaderViewDelegateSpy を使う

@MainActor
final class ReaderViewCensusTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBFixtures.verticalNovel(name: "washi-reader-regression")
    }

    /// 0 始まりの census ページと locator の相互変換は全ページで可逆になる
    func testCensusGlobalPageRoundTripsEveryPage() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let counts = [1, 4, 3]
        let metricsKey = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings).censusOptionsJSON
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: metricsKey, counts: counts,
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        for page in 0..<counts.reduce(0, +) {
            let locator = try XCTUnwrap(view.censusLocator(forGlobalPage: page))
            XCTAssertEqual(view.censusGlobalPage(for: locator), page,
                           "0 始まり page=\(page)")
        }
    }

    /// cooViewer-oxr.73: 公開 locator setter に入った巨大値を、trap する
    /// Double → Int 変換まで到達させない。
    func testCensusGlobalPageClampsHostileLocatorProgression() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let metricsKey = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings).censusOptionsJSON
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: metricsKey, counts: [4, 3, 2],
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        var hostile = EPUBLocator(spineIndex: 0)
        hostile.progression = 1e300
        XCTAssertEqual(view.censusGlobalPage(for: hostile), 3)
    }

    /// cooViewer-oxr.21: A 成功→B 二回失敗→A cache hit→B skip でも、
    /// B 表示中に A の総ページ数を残さない。
    func testSkippedCensusKeyInvalidatesCachedDisplayCounts() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        view.load(publication: publication)
        view.cancelPageCensus()

        let keyA = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: keyA, counts: [2, 3, 1],
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        var settingsB = view.settings
        settingsB.userCSS = "body { line-height: 3; }"
        let keyB = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: settingsB,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        view.recordCensusFailure(forKey: keyB)
        view.recordCensusFailure(forKey: keyB)

        view.settings = settingsB
        view.scheduleCensusIfNeeded()
        XCTAssertNil(view.censusTotalPages)

        var settingsA = settingsB
        settingsA.userCSS = nil
        view.settings = settingsA
        view.scheduleCensusIfNeeded()
        XCTAssertEqual(view.censusTotalPages, 6)

        view.settings = settingsB
        view.scheduleCensusIfNeeded()
        XCTAssertNil(view.censusTotalPages)
        XCTAssertGreaterThanOrEqual(delegate.censusUpdateCount, 4)
    }

    /// cooViewer-oxr.72: stale spineIndex より idref を優先し、通常 go と
    /// census の逆写像が同じ spine を使う。
    func testGoAndCensusGlobalPageResolveLocatorIDRef() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let metricsKey = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: metricsKey, counts: [2, 3, 1],
            releaseIdentifier: publication.metadata.releaseIdentifier)))
        let stale = EPUBLocator(
            spineIndex: 0, progression: 0.5,
            idref: publication.readingOrder[1].itemRef.idref)

        XCTAssertEqual(view.censusGlobalPage(for: stale), 3)
        view.go(to: stale)
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.5, accuracy: 0.0001)
    }

    /// importCensus の照合キーが著者指定を反映した画面計画と決定的に一致する
    func testImportedCensusUsesRenditionSpreadMetricsKey() throws {
        let publication = try EPUBFixtures.reflowSpread(.both)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 900))
        view.load(publication: publication)
        let base = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings)
        let openKey = base.applyingRenditionSpread(.both).cacheKey
        XCTAssertNotEqual(openKey, base.cacheKey)
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: openKey, counts: [7],
            releaseIdentifier: publication.metadata.releaseIdentifier)))
        XCTAssertEqual(view.pageCensusMetricsKey, openKey)
    }
}
