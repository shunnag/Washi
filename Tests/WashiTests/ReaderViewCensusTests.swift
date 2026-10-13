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

    // MARK: - 中断した census の再開

    /// 非表示で止めた census は測り終えた先頭部分を控え、再表示後の同じキーの
    /// census は残りの項目だけを読み込んで、中断なしと同じ配列で完走する
    /// (コレクションで画像ビューと EPUB ビューを行き来しても先頭から測り直さない)。
    func testHiddenCensusKeepsMeasuredPrefixAndResumesAfterUnhide() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        view.load(publication: publication)
        let metrics = view.censusScreenMetrics
        let key = metrics.censusOptionsJSON

        // 2 項目目の setup 直前にビューを隠す(viewDidHide が census を止める)
        let trigger = TriggeringSetupScheduler()
        trigger.triggerAtScheduleCount = 2
        trigger.onTrigger = { view.isHidden = true }
        let interruptedEngine = EPUBPaginationCensus(
            javaScriptTimeoutScheduler: trigger.scheduler)
        // load は実測状態を初期化し、非同期の setup 後に実測を予約する。
        // 最初の await より前に同じ MainActor 上で注入・予約を済ませ、
        // 比較用の実測を待つ間に別のエンジンが先に走る競合を防ぐ。
        view.census.engine = interruptedEngine
        view.scheduleCensusIfNeeded()
        XCTAssertTrue(view.isPageCensusScheduled)

        let reference = EPUBPaginationCensus()
        defer { reference.invalidate() }
        guard let full = await reference.measure(
            publication: publication, optionsJSON: key, contentSize: metrics.contentSize)
        else { return try failOrSkipIfWebKitUnavailable() }

        let stored = await waitUntil(timeout: .seconds(10)) {
            view.census.partialCounts[key] != nil
        }
        XCTAssertTrue(stored, "中断した census の先頭部分が控えられない")
        XCTAssertEqual(view.census.partialCounts[key], Array(full.prefix(1)))
        XCTAssertEqual(interruptedEngine.loadedItemCount, 2)
        XCTAssertNil(view.pageCensus)
        XCTAssertFalse(view.isPageCensusScheduled)

        // 再表示による自動予約より先に、再開用のエンジンも注入する。
        let resumedEngine = EPUBPaginationCensus()
        view.census.engine = resumedEngine
        view.isHidden = false
        view.scheduleCensusIfNeeded()
        let completed = await waitUntil(timeout: .seconds(10)) { view.pageCensus != nil }
        XCTAssertTrue(completed, "再開した census が完走しない")
        XCTAssertEqual(view.pageCensus, full)
        XCTAssertEqual(resumedEngine.loadedItemCount, 2)
        XCTAssertNil(view.census.partialCounts[key])
        XCTAssertEqual(view.census.cache[key], full)
    }

    /// 中断の控えは同じキーにしか使わない: 別のメトリクスの census は先頭から
    /// 全項目を読み込み、元のキーの控えは残る。
    func testPartialCensusIsNotReusedForDifferentKey() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        view.load(publication: publication)
        // load による初期化の後、最初の await より前に注入する。
        // setup 後の自動予約も、別キーの予約もこのエンジンを使う。
        let engine = EPUBPaginationCensus()
        view.census.engine = engine
        let keyA = view.censusScreenMetrics.censusOptionsJSON
        view.census.partialCounts.insert([1], forKey: keyA, protecting: nil)

        var settingsB = view.settings
        settingsB.userCSS = "body { line-height: 3; }"
        view.settings = settingsB
        let keyB = view.censusScreenMetrics.censusOptionsJSON
        XCTAssertNotEqual(keyA, keyB)
        view.scheduleCensusIfNeeded()
        guard await waitUntil(timeout: .seconds(10), { view.pageCensus != nil })
        else { return try failOrSkipIfWebKitUnavailable() }

        XCTAssertEqual(engine.loadedItemCount, 3)
        XCTAssertEqual(view.pageCensus?.count, 3)
        XCTAssertEqual(view.census.partialCounts[keyA], [1])
        XCTAssertNil(view.census.partialCounts[keyB])
    }

    /// 完走結果のキャッシュは上限を守り、表示中のキーを追い出さない。
    func testCensusCacheIsBoundedAndKeepsCurrentKey() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let currentKey = view.censusScreenMetrics.censusOptionsJSON
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: currentKey, counts: [2, 3, 1],
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        for index in 0..<40 {
            var settings = view.settings
            settings.userCSS = "body { line-height: \(index + 2); }"
            let key = EPUBScreenMetrics(
                viewportSize: view.bounds.size, settings: settings,
                renditionSpread: publication.metadata.rendition.spread).censusOptionsJSON
            XCTAssertTrue(view.importCensus(EPUBCensusRecord(
                metricsKey: key, counts: [1, 1, 1],
                releaseIdentifier: publication.metadata.releaseIdentifier)))
            XCTAssertLessThanOrEqual(view.census.cache.count, 16)
            XCTAssertEqual(view.census.cache[currentKey], [2, 3, 1])
        }
        XCTAssertEqual(view.censusTotalPages, 6)
    }

    // MARK: - ライブリサイズ

    /// ライブリサイズ中の layout は census を起動せず延期し、終了時に最終キーで
    /// 一度だけ起動する。同じ寸法のその後の layout は新しい census を始めない。
    func testLiveResizeDefersCensusUntilItEnds() throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-live-resize-census")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        view.load(publication: publication)
        view.cancelPageCensus()
        let startsBefore = view.pageCensusStartCount

        view.isInLiveResizeOverride = true
        for width in [1_000, 1_100, 1_200] {
            view.frame.size.width = CGFloat(width)
            view.layout()
            XCTAssertFalse(view.isPageCensusScheduled)
            XCTAssertTrue(view.hasDeferredCensusForLiveResize)
        }
        XCTAssertEqual(view.pageCensusStartCount, startsBefore)

        view.isInLiveResizeOverride = false
        view.viewDidEndLiveResize()
        XCTAssertTrue(view.isPageCensusScheduled)
        XCTAssertFalse(view.hasDeferredCensusForLiveResize)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore + 1)

        view.layout()
        view.viewDidEndLiveResize()
        XCTAssertEqual(view.pageCensusStartCount, startsBefore + 1)
    }

    /// ライブリサイズ中でも延期するのは実測タスクの起動だけ: キーが変われば
    /// 古い N/M は即座に無効化して delegate へ一度通知し、キャッシュにある
    /// キーへ戻れば即座に適用する(ホストに古い総ページ数を見せない)。
    func testLiveResizeStillInvalidatesAndAppliesCachedCensusImmediately() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus, clearsDelegate: true) }
        view.load(publication: publication)
        view.cancelPageCensus()
        let keyA = view.censusScreenMetrics.censusOptionsJSON
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: keyA, counts: [2, 3, 1],
            releaseIdentifier: publication.metadata.releaseIdentifier)))
        XCTAssertEqual(view.censusTotalPages, 6)
        let startsBefore = view.pageCensusStartCount
        let notifications = delegate.censusUpdateCount

        view.isInLiveResizeOverride = true
        view.frame.size.width = 1_000
        view.scheduleCensusIfNeeded()
        XCTAssertNil(view.pageCensus)
        XCTAssertEqual(delegate.censusUpdateCount, notifications + 1)
        XCTAssertFalse(view.isPageCensusScheduled)
        XCTAssertTrue(view.hasDeferredCensusForLiveResize)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore)

        // 同じ新キーの再呼び出しは通知も起動もしない
        view.scheduleCensusIfNeeded()
        XCTAssertEqual(delegate.censusUpdateCount, notifications + 1)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore)

        // キャッシュにある元の寸法へ戻れば、ドラッグ中でも即座に適用する
        view.frame.size.width = 900
        view.scheduleCensusIfNeeded()
        XCTAssertEqual(view.censusTotalPages, 6)
        XCTAssertEqual(view.pageCensusMetricsKey, keyA)
        XCTAssertEqual(delegate.censusUpdateCount, notifications + 2)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore)

        view.isInLiveResizeOverride = false
        view.viewDidEndLiveResize()
        XCTAssertEqual(view.pageCensusStartCount, startsBefore)
        XCTAssertFalse(view.hasDeferredCensusForLiveResize)
    }

    /// 非表示・ウインドウ離脱で畳むときは延期も捨てる(隠れたまま終わる
    /// リサイズで census を起動しない。再表示時の layout/runSetup が改めて予約する)。
    func testTearDownClearsLiveResizeDeferral() throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-live-resize-teardown")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        view.load(publication: publication)
        view.cancelPageCensus()
        let startsBefore = view.pageCensusStartCount

        view.isInLiveResizeOverride = true
        view.frame.size.width = 1_000
        view.layout()
        XCTAssertTrue(view.hasDeferredCensusForLiveResize)

        view.isHidden = true
        XCTAssertFalse(view.hasDeferredCensusForLiveResize)
        view.isInLiveResizeOverride = false
        view.viewDidEndLiveResize()
        XCTAssertFalse(view.isPageCensusScheduled)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore)
    }

    /// デバウンス中にライブリサイズが始まった census は、古いキーで実測を始めず
    /// 終了時の予約に合流する。
    func testCensusDebouncingWhenLiveResizeStartsDefersToItsEnd() async throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-live-resize-debounce")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = makeOffscreenWindow(containing: view)
        defer { closeReader(view, in: window, teardown: .cancelPageCensus) }
        view.load(publication: publication)
        view.cancelPageCensus()
        let startsBefore = view.pageCensusStartCount

        view.scheduleCensusIfNeeded()
        XCTAssertTrue(view.isPageCensusScheduled)
        view.isInLiveResizeOverride = true
        // 延期フラグは表示中の章の setup 経路でも立つので、デバウンス起床時の
        // 自己退去(タスクの解放)を待つ
        let evicted = await waitUntil(timeout: .seconds(5)) { !view.isPageCensusScheduled }
        XCTAssertTrue(evicted, "デバウンス起床時にライブリサイズへ合流しない")
        XCTAssertTrue(view.hasDeferredCensusForLiveResize)
        XCTAssertNil(view.pageCensus)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore + 1)

        view.isInLiveResizeOverride = false
        view.viewDidEndLiveResize()
        XCTAssertTrue(view.isPageCensusScheduled)
        XCTAssertEqual(view.pageCensusStartCount, startsBefore + 2)
    }
}
