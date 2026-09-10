import XCTest
@testable import Washi

@MainActor
final class EPUBOffscreenIdleReleaseTimerTests: XCTestCase {
    /// cooViewer-oxr.68: キャンセル済み期限が競合して到着しても発火せず、
    /// 置き換えた期限だけが既定の 20 秒後に発火する。
    func testRestartInvalidatesStaleCallbackAndKeepsTwentySecondDeadline() throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let timer = EPUBOffscreenIdleReleaseTimer(scheduler: scheduler.scheduler)
        var releaseCount = 0

        timer.restart { releaseCount += 1 }
        let stale = try XCTUnwrap(scheduler.lastActiveEntry)
        timer.restart { releaseCount += 1 }
        let current = try XCTUnwrap(scheduler.lastActiveEntry)

        XCTAssertTrue(stale.isCancelled)
        XCTAssertEqual(stale.delay, .seconds(20))
        XCTAssertEqual(current.delay, EPUBOffscreenIdleReleaseTimer.defaultInterval)
        scheduler.fire(stale, includingCancelled: true)
        XCTAssertEqual(releaseCount, 0)

        scheduler.fire(current)
        XCTAssertEqual(releaseCount, 1)
    }

    /// cooViewer-oxr.68: scheduler が schedule から戻る前に発火し、callback が
    /// 次の期限を設定しても、最初の cancellation で置き換えてしまわない。
    func testSynchronousFirePreservesReplacementDeadlineCancellation() throws {
        let scheduler = ManualOffscreenIdleScheduler()
        scheduler.firesNextEntrySynchronously = true
        let timer = EPUBOffscreenIdleReleaseTimer(scheduler: scheduler.scheduler)

        timer.restart {
            timer.restart {}
        }
        XCTAssertEqual(scheduler.entries.count, 2)

        timer.cancel()

        XCTAssertTrue(scheduler.entries[0].isCancelled)
        XCTAssertTrue(scheduler.entries[1].isCancelled)
    }

    /// 実 WebKit の代わりに応答しないコールバックを渡し、既定の 5 秒期限で
    /// 待機が戻ることと、遅れて届いた応答が二重解決しないことを確認する。
    func testJavaScriptTimeoutReturnsWithoutResponseAndIgnoresLateReply()
        async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let started = expectation(description: "JS 呼び出し開始")
        let finished = expectation(description: "タイムアウトで待機終了")
        var reply: (@MainActor @Sendable (Int) -> Void)?
        var result: Int?
        var didFinish = false
        let job = Task { @MainActor in
            result = await waitForOffscreenJavaScript(
                timeoutScheduler: scheduler.scheduler
            ) { completion in
                reply = completion
                started.fulfill()
            }
            didFinish = true
            finished.fulfill()
        }
        defer { job.cancel() }
        await fulfillment(of: [started], timeout: 1)
        let timeout = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(timeout.delay, .seconds(5))
        XCTAssertFalse(didFinish)

        scheduler.fire(timeout)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertTrue(didFinish)
        XCTAssertNil(result)
        XCTAssertTrue(timeout.isCancelled)
        reply?(42)
        XCTAssertNil(result)
    }

    /// 実時間の Swift タイマでも無応答待ちが有限時間で終了する。
    /// 退行時にテスト自体が永久待ちしないよう、終了通知にも期限を設ける。
    func testJavaScriptContinuousTimeoutReturnsWithoutResponse() async {
        let finished = expectation(description: "Swift タイマで待機終了")
        var didFinish = false
        let job = Task { @MainActor in
            let result: Int? = await waitForOffscreenJavaScript(
                timeout: .milliseconds(20)
            ) { _ in }
            XCTAssertNil(result)
            didFinish = true
            finished.fulfill()
        }
        defer { job.cancel() }

        await fulfillment(of: [finished], timeout: 1)

        XCTAssertTrue(didFinish)
    }

    /// 応答が continuation の設置より先でも値を返し、不要な期限を回収する。
    /// キャンセル済みのタイマが競合して届いても先着の応答を上書きしない。
    func testJavaScriptResponseWinsAndCancelsTimeout() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let result = await waitForOffscreenJavaScript(
            timeoutScheduler: scheduler.scheduler
        ) { completion in
            completion(7)
            completion(9)
        }

        XCTAssertEqual(result, 7)
        let timeout = try XCTUnwrap(scheduler.entries.last)
        XCTAssertEqual(timeout.delay, .seconds(5))
        XCTAssertTrue(timeout.isCancelled)
        scheduler.fire(timeout, includingCancelled: true)
        XCTAssertEqual(result, 7)
    }

    /// WebKit が応答しなくても呼び出し元のキャンセルで即座に戻り、
    /// 不要になったタイムアウトの期限を回収する。
    func testJavaScriptCancellationReturnsWithoutResponse() async throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let started = expectation(description: "JS 呼び出し開始")
        let finished = expectation(description: "キャンセルで待機終了")
        var didFinish = false
        let job = Task { @MainActor in
            let result: Int? = await waitForOffscreenJavaScript(
                timeoutScheduler: scheduler.scheduler
            ) { _ in started.fulfill() }
            XCTAssertNil(result)
            didFinish = true
            finished.fulfill()
        }
        defer { job.cancel() }
        await fulfillment(of: [started], timeout: 1)
        let timeout = try XCTUnwrap(scheduler.lastActiveEntry)

        job.cancel()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertTrue(didFinish)
        XCTAssertTrue(timeout.isCancelled)
    }
}
