import AppKit
import XCTest
@testable import Washi

/// `EPUBPageRasterizer.idleReleaseInterval`(任意加入のアイドル解放)。
/// 期限は差し替えた scheduler の仮想時刻で進め、実時間は待たない。
@MainActor
final class EPUBPageRasterizerIdleReleaseTests: XCTestCase {
    /// 既定(nil)では期限を一度も予約せず、描画後も同じ WebKit を保持する(従来の契約)。
    func testDefaultNeverSchedulesIdleRelease() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let rasterizer = try makeRasterizer(scheduler: scheduler, name: "washi-raster-idle-default")
        defer { rasterizer.invalidate() }
        XCTAssertNil(rasterizer.idleReleaseInterval)

        guard let first = await render(rasterizer) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let webView = try XCTUnwrap(rasterizer.webView)
        let second = await render(rasterizer)

        XCTAssertEqual(second?.width, first.width)
        XCTAssertTrue(rasterizer.webView === webView)
        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertTrue(rasterizer.hasLiveWebView)
    }

    /// 期限を設定すると、描画完了からちょうどその時間で解放し(手前では保持)、
    /// 次の描画は初回と同じ経路で作り直して同じピクセル寸法を返す。
    func testIdleReleaseFiresAfterIntervalAndNextRenderRebuilds() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let rasterizer = try makeRasterizer(scheduler: scheduler, name: "washi-raster-idle-release")
        defer { rasterizer.invalidate() }
        rasterizer.idleReleaseInterval = .seconds(5)
        XCTAssertTrue(scheduler.entries.isEmpty)  // WebKit がまだ無いので予約しない

        guard let first = await render(rasterizer) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        XCTAssertTrue(rasterizer.hasLiveWebView)
        XCTAssertEqual(scheduler.lastActiveEntry?.delay, .seconds(5))

        scheduler.advance(by: .seconds(4))
        XCTAssertTrue(rasterizer.hasLiveWebView)
        scheduler.advance(by: .seconds(1))
        XCTAssertFalse(rasterizer.hasLiveWebView)
        XCTAssertNil(rasterizer.window)

        let rebuiltImage = await render(rasterizer)
        let rebuilt = try XCTUnwrap(rebuiltImage)
        XCTAssertEqual(rebuilt.width, first.width)
        XCTAssertEqual(rebuilt.height, first.height)
        XCTAssertTrue(rasterizer.hasLiveWebView)
        XCTAssertEqual(scheduler.lastActiveEntry?.delay, .seconds(5))
    }

    /// 描画中(FIFO 待ちを含む)は解放しない: 新しい要求が旧期限を失効させ、競合して
    /// 届いた旧 callback も、描画中の設定変更も WebKit を畳まず、何も予約しない。
    func testIdleReleaseDoesNotFireDuringRender() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let rasterizer = try makeRasterizer(scheduler: scheduler, name: "washi-raster-idle-busy")
        defer { rasterizer.invalidate() }
        rasterizer.idleReleaseInterval = .seconds(5)
        guard let first = await render(rasterizer) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let staleIdle = try XCTUnwrap(scheduler.lastActiveEntry)
        let webView = try XCTUnwrap(rasterizer.webView)

        let inFlight = Task { @MainActor in await render(rasterizer) }
        let queued = Task { @MainActor in await render(rasterizer) }
        // 要求の受付(旧期限の失効)は enqueue の最初の await より前に済むので、
        // 旧期限が失効した時点で少なくとも先頭の要求は busy として数えられている
        // (ラスタライザには描画を止める差し替え点がないので、開始の観測はこの待ちで行う)。
        for _ in 0..<100 {
            if staleIdle.isCancelled { break }
            await Task.yield()
        }
        XCTAssertTrue(staleIdle.isCancelled)
        XCTAssertNil(scheduler.lastActiveEntry)

        scheduler.fire(staleIdle, includingCancelled: true)
        XCTAssertTrue(rasterizer.hasLiveWebView)
        rasterizer.idleReleaseInterval = .seconds(3)
        XCTAssertNil(scheduler.lastActiveEntry)
        XCTAssertTrue(rasterizer.webView === webView)

        let inFlightResult = await inFlight.value
        let queuedResult = await queued.value
        let inFlightImage = try XCTUnwrap(inFlightResult)
        let queuedImage = try XCTUnwrap(queuedResult)
        XCTAssertEqual(inFlightImage.width, first.width)
        XCTAssertEqual(queuedImage.width, first.width)
        XCTAssertTrue(rasterizer.hasLiveWebView)
        XCTAssertEqual(scheduler.lastActiveEntry?.delay, .seconds(3))
    }

    /// アイドル中に期限を変えると新しい時間で予約し直し、nil に戻すと予約を外し、
    /// 0 以下は待機なしの解放を予約する。
    func testChangingIntervalWhileIdleRearmsOrCancels() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let rasterizer = try makeRasterizer(scheduler: scheduler, name: "washi-raster-idle-rearm")
        defer { rasterizer.invalidate() }
        guard await render(rasterizer) != nil else {
            return try failOrSkipIfWebKitUnavailable()
        }
        XCTAssertTrue(scheduler.entries.isEmpty)

        rasterizer.idleReleaseInterval = .seconds(3)
        let armed = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(armed.delay, .seconds(3))

        rasterizer.idleReleaseInterval = .seconds(7)
        XCTAssertTrue(armed.isCancelled)
        let rearmed = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(rearmed.delay, .seconds(7))

        rasterizer.idleReleaseInterval = nil
        XCTAssertTrue(rearmed.isCancelled)
        XCTAssertNil(scheduler.lastActiveEntry)
        scheduler.fire(rearmed, includingCancelled: true)
        XCTAssertTrue(rasterizer.hasLiveWebView)

        rasterizer.idleReleaseInterval = .seconds(-1)
        let immediate = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(immediate.delay, .zero)
        scheduler.advance(by: .zero)
        XCTAssertFalse(rasterizer.hasLiveWebView)
    }

    /// invalidate はアイドル期限を外し、競合して届いた旧 callback を無視し、以後の
    /// 描画を loadFailed で拒否する(アイドル解放のような再構築はしない)。
    func testInvalidateCancelsIdleDeadlineAndRejectsNewRender() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let rasterizer = try makeRasterizer(scheduler: scheduler, name: "washi-raster-idle-invalidate")
        rasterizer.idleReleaseInterval = .seconds(2)
        guard await render(rasterizer) != nil else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let stale = try XCTUnwrap(scheduler.lastActiveEntry)

        rasterizer.invalidate()

        XCTAssertTrue(stale.isCancelled)
        scheduler.fire(stale, includingCancelled: true)
        XCTAssertFalse(rasterizer.hasLiveWebView)
        do {
            _ = try await rasterizer.renderPage(atSpineIndex: 0, maxPixelSize: 160)
            XCTFail("無効化後の描画は失敗する")
        } catch {
            XCTAssertEqual(error as? EPUBPageRasterizer.RasterizeError, .loadFailed)
        }
        XCTAssertFalse(rasterizer.hasLiveWebView)
        XCTAssertNil(scheduler.lastActiveEntry)
    }

    private func makeRasterizer(scheduler: ManualOffscreenIdleScheduler,
                                name: String) throws -> EPUBPageRasterizer {
        EPUBPageRasterizer(
            publication: try EPUBFixtures.fxlComic(name: name),
            allowsScriptedContent: false, idleTimerScheduler: scheduler.scheduler)
    }

    private func render(_ rasterizer: EPUBPageRasterizer) async -> CGImage? {
        try? await rasterizer.renderPage(atSpineIndex: 0, maxPixelSize: 160)
    }
}
