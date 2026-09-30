import AppKit
import WebKit
import XCTest
@testable import Washi

// 保存したテキストアンカーへの着地と、見つからないときの進行率への復帰

@MainActor
final class ReaderViewTextAnchorLandingTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBFixtures.verticalNovel(name: "washi-reader-regression")
    }

    /// 完了待ち要求のない go(locator:) と goBack() も保存した文字を探す。
    /// ページ割りを変え、進行率への移動だけでは成功とみなさない。
    func testSavedTextAnchorAndHistoryUseExactLandingWithoutContinuation() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.preparePublication(publication)
        defer { view.unload() }
        var saved = publication.locator(forSpineIndex: 0, progression: 0.25)
        saved.textOffset = 420
        view.settings.fontScale = 1.5
        view.frame.size.width = 800
        var offsets: [Int] = []
        var scripts: [String] = []
        view.textRangeLocationHandler = { offset, length in
            offsets.append(offset)
            XCTAssertEqual(length, 1)
            return EPUBTextRangeLanding(pageInItem: 7, text: "保存した文",
                                       rects: [CGRect(x: 10, y: 20, width: 40, height: 20)])
        }
        view.scriptEvaluationHandler = { scripts.append($0) }

        view.go(to: saved)
        await view.textRangeTask?.value

        XCTAssertEqual(offsets, [420])
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertEqual(view.currentLocator.textOffset, 420)
        XCTAssertNil(view.textRangeTask)

        view.go(to: publication.locator(forSpineIndex: 0, progression: 0.9))
        XCTAssertEqual(scripts, ["__washi.showProgression(0.9);"])
        scripts.removeAll()
        view.goBack()
        await view.textRangeTask?.value

        XCTAssertEqual(offsets, [420, 420])
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertEqual(view.currentLocator.textOffset, 420)
    }

    /// アンカーを探した結果が nil のときだけ、保存済みの進行率へ戻す。
    func testMissingTextAnchorFallsBackAfterAttemptingExactLanding() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: .zero)
        view.preparePublication(publication)
        defer { view.unload() }
        var saved = publication.locator(forSpineIndex: 0, progression: 0.625)
        saved.textOffset = 999
        var attempted = false
        var scripts: [String] = []
        view.textRangeLocationHandler = { offset, _ in
            XCTAssertEqual(offset, 999)
            attempted = true
            return nil
        }
        view.scriptEvaluationHandler = { script in
            XCTAssertTrue(attempted)
            scripts.append(script)
        }

        view.go(to: saved)
        await view.textRangeTask?.value

        XCTAssertTrue(attempted)
        XCTAssertEqual(scripts, ["__washi.showProgression(0.625);"])
    }

    /// 継続を持つ既存の async API は、正確な着地結果を引き続き返す。
    func testAsyncTextRangeNavigationStillCompletesWithLanding() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: .zero)
        view.preparePublication(publication)
        defer { view.unload() }
        let landing = EPUBTextRangeLanding(
            pageInItem: 3, text: "本文", rects: [CGRect(x: 0, y: 0, width: 20, height: 20)])
        view.textRangeLocationHandler = { offset, length in
            XCTAssertEqual(offset, 12)
            XCTAssertEqual(length, 2)
            return landing
        }
        view.scriptEvaluationHandler = { _ in XCTFail("正確に着地できた場合は進行率へ戻さない") }

        let result = await view.go(
            to: publication.locator(forSpineIndex: 0, progression: 0.4),
            textRange: (utf16Offset: 12, utf16Length: 2))

        XCTAssertEqual(result?.pageInItem, landing.pageInItem)
        XCTAssertEqual(result?.text, landing.text)
        XCTAssertEqual(result?.rects, landing.rects)
        XCTAssertNil(view.textRangeTask)
    }

    /// unload より後に返った旧アンカーの応答は、次の本へ fallback を送らない。
    func testUnloadCancelsInFlightTextAnchorBeforeFallback() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(frame: .zero)
        view.preparePublication(publication)
        var saved = publication.locator(forSpineIndex: 0, progression: 0.75)
        saved.textOffset = 42
        let started = expectation(description: "アンカー解決を開始")
        var continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>?
        var scripts: [String] = []
        view.textRangeLocationHandler = { _, _ in
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        view.scriptEvaluationHandler = { scripts.append($0) }
        view.go(to: saved)
        let task = try XCTUnwrap(view.textRangeTask)
        await fulfillment(of: [started], timeout: 1)

        view.unload()
        continuation?.resume(returning: nil)
        await task.value

        XCTAssertTrue(scripts.isEmpty)
        XCTAssertNil(view.textRangeTask)
        XCTAssertNil(view.publication)
    }
}
