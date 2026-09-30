import AppKit
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

@MainActor
final class EPUBPaginationCensusTests: XCTestCase {
    /// cooViewer-oxr.68: 完了から 20 秒相当で WebKit を解放し、同じ census の
    /// 次回計測で遅延再構築して同じ結果を返す。
    func testIdleReleaseTearsDownWebViewAndNextMeasureRebuilds() async throws {
        let publication = try makeReflowPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let census = EPUBPaginationCensus(
            idleTimerScheduler: scheduler.scheduler)
        defer { census.invalidate() }
        let metrics = makeMetrics()

        guard let first = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize) else {
            return try failOrSkipIfWebKitUnavailable()
        }

        XCTAssertTrue(census.hasLiveWebView)
        let idle = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(idle.delay, EPUBOffscreenIdleReleaseTimer.defaultInterval)

        scheduler.fire(idle)
        XCTAssertFalse(census.hasLiveWebView)

        let rebuilt = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)
        XCTAssertEqual(rebuilt, Optional(first))
        XCTAssertTrue(census.hasLiveWebView)
    }

    /// cooViewer-oxr.68: 新しい計測が始めた時点で旧 idle callback を失効させ、
    /// callback が競合して到着しても進行中の WebKit を畳まない。
    func testStaleIdleTimerDoesNotInterruptInFlightMeasure() async throws {
        let publication = try makeReflowPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let census = EPUBPaginationCensus(
            idleTimerScheduler: scheduler.scheduler)
        defer { census.invalidate() }
        let metrics = makeMetrics()
        guard let first = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let staleIdle = try XCTUnwrap(scheduler.lastActiveEntry)

        let inFlight = Task { @MainActor in
            await census.measure(
                publication: publication,
                optionsJSON: metrics.censusOptionsJSON,
                contentSize: metrics.contentSize)
        }
        for _ in 0..<100 {
            if staleIdle.isCancelled { break }
            await Task.yield()
        }
        XCTAssertTrue(staleIdle.isCancelled)

        scheduler.fire(staleIdle, includingCancelled: true)
        XCTAssertTrue(census.hasLiveWebView)
        let inFlightResult = await inFlight.value
        XCTAssertEqual(inFlightResult, Optional(first))
    }

    /// cooViewer-oxr.22: spine 内の欠損 XHTML は 1 ページへ縮退し、
    /// 後続の正常項目まで含む census を完成させる。
    func testMissingSpineResourceCountsAsOneAndCensusContinues() async throws {
        let publication = try makePublicationWithMissingSpineResource()
        let census = EPUBPaginationCensus()
        defer { census.invalidate() }
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600), settings: settings)

        let counts = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)

        XCTAssertEqual(counts, [1, 1])
    }

    /// cooViewer-oxr.22/53: caller cancellation は部分結果へ縮退せず nil を返す。
    func testCancellationReturnsNil() async throws {
        let publication = try makePublicationWithMissingSpineResource()
        let census = EPUBPaginationCensus()
        defer { census.invalidate() }
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600),
            settings: EPUBReaderSettings())
        let task = Task { @MainActor in
            await census.measure(
                publication: publication,
                optionsJSON: metrics.censusOptionsJSON,
                contentSize: metrics.contentSize)
        }
        task.cancel()

        let counts = await task.value
        XCTAssertNil(counts)
    }

    /// 応答しない JS を 1 ページの正常計測として返すと、その値が atlas や
    /// 保存済み census に残る。期限切れは失敗にし、次回は再計測できること。
    func testJavaScriptTimeoutDoesNotBecomeSuccessfulPageCount() async throws {
        let publication = try makeReflowPublication()
        let timeout = ManualOffscreenIdleScheduler()
        timeout.firesNextEntrySynchronously = true
        let census = EPUBPaginationCensus(
            javaScriptTimeoutScheduler: timeout.scheduler)
        defer { census.invalidate() }
        let metrics = makeMetrics()

        // 正常な計測条件のまま、JS の応答より先に Swift 側の期限を発火する。
        let timedOut = await census.measure(
            publication: publication,
            optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)

        guard let entry = timeout.entries.first else {
            return try failOrSkipWebKitTest("WKWebView の読み込みが JS 計測まで進みませんでした")
        }
        XCTAssertEqual(timeout.entries.count, 1)
        XCTAssertTrue(entry.isFired)
        XCTAssertNil(timedOut)
        XCTAssertFalse(census.hasLiveWebView)
        let retried = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)
        XCTAssertEqual(retried, [1])
    }

    /// Washi-z74.13: 読み込み完了後・setup 実行前(NavigationWaiter の再開と
    /// MainActor での再開の間に相当)に invalidate されたら、取得済みの
    /// WebView で続行せず、次の項目のウインドウも作り直さず nil で抜ける。
    /// 同じ census は invalidate 後の次の measure で作り直せる。
    func testInvalidateDuringMeasurementStopsCensusWithoutRebuilding() async throws {
        let publication = try makeTwoItemReflowPublication()
        let invalidator = InvalidatingSetupScheduler()
        let census = EPUBPaginationCensus(
            javaScriptTimeoutScheduler: invalidator.scheduler)
        defer { census.invalidate() }
        invalidator.census = census
        let metrics = makeMetrics()

        let interrupted = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)

        guard invalidator.scheduleCount > 0 else {
            return try failOrSkipWebKitTest("WKWebView の読み込みが JS 計測まで進みませんでした")
        }
        XCTAssertNil(interrupted)
        // 2 項目目を実測しに行けば setup の期限が 2 回目に予約される。
        XCTAssertEqual(invalidator.scheduleCount, 1)
        XCTAssertFalse(census.hasLiveWebView)

        let rebuilt = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)
        XCTAssertEqual(rebuilt, [1, 1])
        XCTAssertTrue(census.hasLiveWebView)
    }

    /// cooViewer-oxr.22/53: WebKit の load 中断・プロセス終了は壊れた項目の
    /// 1 ページ縮退ではなく、census 全体を中断する一過性エラーとして扱う。
    func testTransientWebKitFailuresAbortMeasurement() {
        XCTAssertTrue(EPUBPaginationCensus.mustAbortMeasurement(for: NSError(
            domain: "WebKitErrorDomain", code: 102)))
        XCTAssertTrue(EPUBPaginationCensus.mustAbortMeasurement(for: NSError(
            domain: WKError.errorDomain,
            code: WKError.Code.webContentProcessTerminated.rawValue)))
        XCTAssertFalse(EPUBPaginationCensus.mustAbortMeasurement(for: URLError(
            .fileDoesNotExist)))
    }

    private func makePublicationWithMissingSpineResource() throws
        -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:census-missing</dc:identifier>
                <dc:title>Census missing item</dc:title>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="missing" href="text/missing.xhtml"
                      media-type="application/xhtml+xml"/>
                <item id="present" href="text/present.xhtml"
                      media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="missing"/>
                <itemref idref="present"
                         properties="rendition:layout-pre-paginated"/>
              </spine>
            </package>
            """
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Present</title></head>
              <body><p>Present spine item.</p></body>
            </html>
            """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/present.xhtml", Data(xhtml.utf8)),
        ]
        return try EPUBFixtures.publication(entries, name: "washi-census-missing")
    }

    /// リフロー 2 項目の本。1 項目目の setup 中に invalidate されたとき、
    /// 2 項目目でウインドウを作り直すかどうかを観測するために使う。
    private func makeTwoItemReflowPublication() throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:census-two-items</dc:identifier>
                <dc:title>Census two items</dc:title>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"/>
                <item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="a"/>
                <itemref idref="b"/>
              </spine>
            </package>
            """
        func xhtml(_ title: String) -> Data {
            Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <head><title>\(title)</title></head>
                  <body><p>\(title) spine item.</p></body>
                </html>
                """.utf8)
        }
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/a.xhtml", xhtml("First")),
            ("OEBPS/text/b.xhtml", xhtml("Second")),
        ]
        return try EPUBFixtures.publication(entries, name: "washi-census-two-items")
    }

    private func makeReflowPublication() throws -> EPUBPublication {
        try EPUBFixtures.publication(
            EPUBFixtures.reflowSpreadEntries(
                renditionSpread: .none, bodyHTML: "<p>Idle census lifecycle fixture.</p>"),
            name: "washi-census-idle-release")
    }

    private func makeMetrics() -> EPUBScreenMetrics {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        return EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600), settings: settings)
    }
}

/// Washi-z74.13: setup の期限を予約する瞬間(読み込み完了後・JS 実行前)に
/// census を invalidate し、以後の期限は実時間の scheduler へ委ねる
/// (WebView が応答しなくても 5 秒で抜けるので、テストが止まらない)。
@MainActor
private final class InvalidatingSetupScheduler {
    weak var census: EPUBPaginationCensus?
    private(set) var scheduleCount = 0

    var scheduler: EPUBOffscreenIdleReleaseTimer.Scheduler {
        { [weak self] delay, action in
            guard let self else { return {} }
            scheduleCount += 1
            if scheduleCount == 1 {
                census?.invalidate()
            }
            return EPUBOffscreenIdleReleaseTimer.continuousScheduler(delay, action)
        }
    }
}
