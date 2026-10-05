import AppKit
import XCTest
@testable import Washi

@MainActor
final class ScrolledFlowWheelTests: XCTestCase {
    func testVerticalRLContinuousWheelKeepsContainerAndChildrenInSync() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["vertical-rl", "vertical-rl"])
        let harness = ScrolledFlowWheelHarness()
        defer { harness.close() }
        try await harness.load(book, at: book.locator(forSpineIndex: 0, progression: 0.4))
        let initial = try await harness.offset()
        XCTAssertGreaterThan(initial, 132)
        let initialMetrics = try await harness.metrics()
        XCTAssertLessThan(try XCTUnwrap(initialMetrics["scrollX"] as? Double), 0)

        try await harness.gesture(dy: -12)
        try await assertPosition(harness, initial + 132)
        try await assertChildrenInSync(harness)
        try await harness.gesture(dy: 12)
        try await assertPosition(harness, initial)
        try await assertChildrenInSync(harness)

        // WebKit に渡していた横操作は、逆向きで 2 倍戻り、子文書が古い位置に残った。
        try await harness.gesture(dx: 12)
        try await assertPosition(harness, initial + 132)
        try await assertChildrenInSync(harness)
        try await harness.gesture(dx: -12)
        try await assertPosition(harness, initial)
        try await assertChildrenInSync(harness)
        XCTAssertTrue(harness.consumedEvents.allSatisfy { $0 })
        let metrics = try await harness.metrics()
        XCTAssertEqual(metrics["domWheels"] as? Int, 0, "native と DOM の二重適用を防ぐ")
        XCTAssertGreaterThan(try XCTUnwrap(metrics["nativeCalls"] as? Int), 0)
        XCTAssertTrue(harness.spy.failures.isEmpty)
    }

    func testVerticalRLDocumentWheelAtOriginAndNegativeScrollXIncludingNotches() async throws {
        let book = try scrollPublication(modes: ["vertical-rl", "vertical-rl"])
        let harness = ScrolledFlowWheelHarness()
        defer { harness.close() }
        try await harness.load(book)
        try await assertPosition(harness, 0)
        let origin = try await harness.metrics()
        XCTAssertEqual(origin["scrollX"] as? Double, 0)
        try await harness.gesture(dy: -12)
        try await assertPosition(harness, 132)
        try await harness.gesture(dy: 12)
        try await assertPosition(harness, 0)

        _ = try await harness.reader.evaluateForTest("return __washi.showProgression(0.4);")
        let initial = try await harness.offset()
        let middle = try await harness.metrics()
        XCTAssertLessThan(try XCTUnwrap(middle["scrollX"] as? Double), 0)
        try await harness.gesture(dy: -12)
        try await assertPosition(harness, initial + 132)
        try await harness.gesture(dy: 12)
        try await assertPosition(harness, initial)

        try harness.send(dy: -1, precise: false, phase: 0)
        await harness.drain()
        try await assertPosition(harness, initial + 40)
        try harness.send(dy: 1, precise: false, phase: 0)
        await harness.drain()
        try await assertPosition(harness, initial)
        XCTAssertTrue(harness.consumedEvents.allSatisfy { $0 })
        let metrics = try await harness.metrics()
        XCTAssertEqual(metrics["domWheels"] as? Int, 0)
    }

    func testContinuousWheelCrossesChapterBoundaryAndReturnsWithoutReloading() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["vertical-rl", "vertical-rl"])
        let harness = ScrolledFlowWheelHarness()
        defer { harness.close() }
        try await harness.load(book)
        let webView = try harness.reader.firstWebView()
        _ = try await harness.reader.evaluateForTest("""
            const metrics = __washi.scrollMetrics();
            return __washi.showProgression((metrics.items[1].start - 66) / metrics.items[0].extent);
            """)
        let initial = try await harness.offset()
        let metrics = try await harness.metrics()
        XCTAssertLessThan(try XCTUnwrap(metrics["scrollX"] as? Double), 0)
        try await harness.gesture(dy: -12)
        try await assertPosition(harness, initial + 132)
        let crossed = await waitUntil(timeout: .seconds(3)) { harness.reader.currentSpineIndex == 1 }
        XCTAssertTrue(crossed)
        try await assertChildrenInSync(harness)
        try await harness.gesture(dy: 12)
        try await assertPosition(harness, initial)
        let returned = await waitUntil(timeout: .seconds(3)) { harness.reader.currentSpineIndex == 0 }
        XCTAssertTrue(returned)
        try await assertChildrenInSync(harness)
        XCTAssertTrue(webView === harness.reader.webView)
        XCTAssertTrue(harness.spy.failures.isEmpty)
    }

    func testCoalescedDirectionChangesPreserveMovementAtDocumentEdges() async throws {
        for flow in ["scrolled-doc", "scrolled-continuous"] {
            let book = try scrollPublication(flow: flow, modes: ["vertical-rl", "vertical-rl"])
            let harness = ScrolledFlowWheelHarness()
            defer { harness.close() }
            try await harness.load(book)
            // 先頭での戻りは制限されるが、続く送りは 20px 動く。合計 0 ではない。
            try harness.send(dy: 20)
            try harness.send(dy: -20)
            await harness.drain()
            try await assertPosition(harness, 20)
            _ = try await harness.reader.evaluateForTest("""
                const metrics = __washi.scrollMetrics();
                window.scrollTo(-(metrics.extent - metrics.viewport), 0);
                return true;
                """)
            let maximum = try await harness.offset()
            try harness.send(dy: -40)
            try harness.send(dy: 40)
            await harness.drain()
            try await assertPosition(harness, maximum - 40)
            XCTAssertTrue(harness.spy.edges.isEmpty)
        }
    }

    func testGestureAxisStaysLockedThroughChangesAndMomentum() async throws {
        for flow in ["scrolled-doc", "scrolled-continuous"] {
            for mode in ["vertical-rl", "vertical-lr"] {
                let book = try scrollPublication(flow: flow, modes: [mode, mode])
                let harness = ScrolledFlowWheelHarness()
                defer { harness.close() }
                try await harness.load(book, at: book.locator(forSpineIndex: 0, progression: 0.4))
                let initial = try await harness.offset()
                let forwardX: Int32 = mode == "vertical-rl" ? 35 : -35
                try harness.send(phase: 128)
                XCTAssertNil(harness.reader.scrolledWheel.horizontal)
                try harness.send(dx: 10, dy: -35, phase: 1)
                await harness.drain()
                try await assertPosition(harness, initial + 35)
                // 優勢軸が変わっても縦軸を使い、横デルタで方向を反転させない。
                try harness.send(dx: forwardX, dy: -10)
                await harness.drain()
                try await assertPosition(harness, initial + 45)
                try harness.send(phase: 4)
                try harness.send(dx: -forwardX, dy: -5, phase: 0, momentum: 1)
                try harness.send(dx: forwardX, dy: -8, phase: 0, momentum: 2)
                try harness.send(phase: 0, momentum: 3)
                await harness.drain()
                try await assertPosition(harness, initial + 58)
                XCTAssertEqual(harness.reader.scrolledWheel.horizontal, false)
                if flow == "scrolled-continuous" {
                    // 次の began で軸を取り直し、横軸も慣性の終わりまで固定する。
                    try harness.send(dx: forwardX, dy: 10, phase: 1)
                    try harness.send(dx: forwardX > 0 ? 10 : -10, dy: 35)
                    try harness.send(phase: 4)
                    try harness.send(dx: forwardX > 0 ? 5 : -5, dy: 20, phase: 0, momentum: 1)
                    try harness.send(phase: 0, momentum: 3)
                    await harness.drain()
                    try await assertPosition(harness, initial + 108)
                    try await assertChildrenInSync(harness)
                }
            }
        }
    }

    func testPhaseLessEventsUseTheirDominantAxisWithoutAGesture() async throws {
        for mode in ["vertical-rl", "vertical-lr"] {
            let book = try scrollPublication(flow: "scrolled-continuous", modes: [mode, mode])
            let harness = ScrolledFlowWheelHarness()
            defer { harness.close() }
            try await harness.load(book, at: book.locator(forSpineIndex: 0, progression: 0.4))
            let initial = try await harness.offset()
            // 軸を持たないまま phase が終わり、静穏区切りもまだない単発イベント。
            try harness.send(phase: 1)
            try harness.send(phase: 4)
            try harness.send(dx: mode == "vertical-rl" ? 35 : -35, dy: 10, phase: 0)
            await harness.drain()
            try await assertPosition(harness, initial + 35)
            try harness.send(dx: -10, dy: -35, phase: 0)
            await harness.drain()
            try await assertPosition(harness, initial + 70)
            try harness.send(dx: 12, dy: -12, phase: 0)
            await harness.drain()
            try await assertPosition(harness, initial + 82, "同値なら縦デルタを使う")
        }
    }

    func testPhaseLessMouseWheelLocksAxisUntilQuiet() async throws {
        let book = try scrollPublication(flow: "scrolled-continuous", modes: ["vertical-rl", "vertical-rl"])
        let harness = ScrolledFlowWheelHarness()
        defer { harness.close() }
        try await harness.load(book, at: book.locator(forSpineIndex: 0, progression: 0.4))
        let initial = try await harness.offset()
        try harness.send(dy: -1, precise: false, phase: 0)
        try harness.send(dx: 2, dy: -1, precise: false, phase: 0)
        await harness.drain()
        try await assertPosition(harness, initial + 80, "静穏の後に決めた縦軸を維持する")
        XCTAssertEqual(harness.reader.scrolledWheel.horizontal, false)
        harness.reader.scrolledWheel.lastTime -= 0.3
        try harness.send(dx: 2, dy: -1, precise: false, phase: 0)
        await harness.drain()
        try await assertPosition(harness, initial + 160, "次の静穏で横軸へ取り直す")
        XCTAssertEqual(harness.reader.scrolledWheel.horizontal, true)
    }

    func testVerticalDocumentHorizontalGestureAndMomentumStayInWebKit() async throws {
        for mode in ["vertical-rl", "vertical-lr"] {
            let book = try scrollPublication(modes: [mode])
            let harness = ScrolledFlowWheelHarness()
            defer { harness.close() }
            try await harness.load(book)
            let forwardX: Int32 = mode == "vertical-rl" ? 12 : -12
            try await harness.gesture(dx: forwardX)
            let moved = try await harness.waitForMovement(from: 0)
            XCTAssertGreaterThan(moved, 0)
            var metrics = try await harness.metrics()
            XCTAssertTrue((metrics["domWheels"] as? Int ?? 0) > 0 || moved > 0,
                          "横操作が DOM に届くか WebKit が自前でスクロールする")
            XCTAssertEqual(metrics["nativeCalls"] as? Int, 0)
            XCTAssertTrue(harness.consumedEvents.allSatisfy { !$0 })
            // 慣性の優勢軸が縦に変わっても、横ジェスチャの回し先を変えない。
            try harness.send(dx: forwardX, dy: -35, phase: 0, momentum: 1)
            try harness.send(phase: 0, momentum: 3)
            XCTAssertTrue(harness.consumedEvents.suffix(2).allSatisfy { !$0 })
            try await Task.sleep(for: .milliseconds(250))
            let initial = try await harness.offset()
            try await harness.gesture(dy: -12)
            try await assertPosition(harness, initial + 132)
            XCTAssertTrue(harness.consumedEvents.suffix(12).allSatisfy { $0 })
            metrics = try await harness.metrics()
            XCTAssertGreaterThan(try XCTUnwrap(metrics["nativeCalls"] as? Int), 0)
        }
    }

    func testPreciseFractionalDeltasMoveSymmetricallyAcrossFlushes() async throws {
        for flow in ["scrolled-doc", "scrolled-continuous"] {
            for mode in ["vertical-rl", "vertical-lr"] {
                let book = try scrollPublication(flow: flow, modes: [mode, mode])
                let harness = ScrolledFlowWheelHarness()
                defer { harness.close() }
                try await harness.load(book, at: book.locator(forSpineIndex: 0, progression: 0.4))
                let initial = try await harness.offset()
                for index in 0..<25 {
                    try harness.sendFractional(dy: -0.4, phase: index == 0 ? 1 : 2)
                    await harness.drain()
                }
                let forward = try await harness.offset()
                XCTAssertGreaterThan(forward - initial, 8, "0.4px の各 flush を捨てない")
                try await assertPosition(harness, initial + 10)
                try harness.send(phase: 4)
                for index in 0..<25 {
                    try harness.sendFractional(dy: 0.4, phase: index == 0 ? 1 : 2)
                    await harness.drain()
                }
                try await assertPosition(harness, initial, "往復が対称になる")
                if flow == "scrolled-continuous" { try await assertChildrenInSync(harness) }
            }
        }
    }

    func testFractionalRemainderClearsOnDirectionChangeGestureStartAndReset() async throws {
        let harness = ScrolledFlowWheelHarness()
        defer { harness.close() }
        try await harness.load(try scrollPublication(modes: ["vertical-rl"]))
        try harness.sendFractional(dy: -0.75, phase: 1)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0.75)
        try harness.sendFractional(dy: 0.5)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, -0.5)
        try await assertPosition(harness, 0)
        try harness.send(phase: 128)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0)
        try harness.sendFractional(dy: -0.5)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0.5)
        try harness.sendFractional(dy: -0.5, phase: 1)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0.5)
        // phase のないホイールの静穏も新しい操作として端数を捨てる。
        harness.reader.scrolledWheel.lastTime -= 0.3
        try harness.sendFractional(dy: -0.5, phase: 0)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0.5)
        try await assertPosition(harness, 0)
        let book = try scrollPublication(modes: ["vertical-rl"])
        try await harness.load(book)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0)
        try await assertPosition(harness, 0)
    }

    func testDocumentWheelDebouncesPageChangedAndDelegateMoves() async throws {
        for mode in ["horizontal-tb", "vertical-rl"] {
            let harness = ScrolledFlowWheelHarness()
            defer { harness.close() }
            try await harness.load(try scrollPublication(modes: [mode]))
            try await Task.sleep(for: .milliseconds(200))
            _ = try await harness.reader.evaluateForTest("""
                const stats = { wheelCalls:0, reportsDuringWheel:0 };
                globalThis.__wheelReportStats = stats;
                let runningWheel = false;
                const scroll = __washi.scrollByWheelDelta;
                __washi.scrollByWheelDelta = (...args) => {
                    stats.wheelCalls += 1;
                    runningWheel = true;
                    try { return scroll(...args); }
                    finally { runningWheel = false; }
                };
                const token = \(ReaderScripts.jsStringLiteral(harness.reader.currentDocumentToken));
                __washi.hostPost = message => {
                    // guard の途中通知は許し、ホイール関数が直接送った通知だけを数える。
                    if (message.type === 'pageChanged' && runningWheel) { stats.reportsDuringWheel += 1; }
                    message.token = token;
                    window.webkit.messageHandlers.washi.postMessage(message);
                };
                return true;
                """)
            let before = harness.spy.moveCount
            try await harness.gesture(dy: -12)
            let reported = await waitUntil(timeout: .seconds(3)) { harness.spy.moveCount > before }
            XCTAssertTrue(reported, "scroll guard が最後の位置を通知する")
            try await Task.sleep(for: .milliseconds(200))
            if mode == "vertical-rl" {
                let value = try await harness.reader.evaluateForTest("return globalThis.__wheelReportStats;")
                let stats = try XCTUnwrap(value as? [String: Any])
                XCTAssertGreaterThan(try XCTUnwrap(stats["wheelCalls"] as? Int), 0)
                XCTAssertEqual(try XCTUnwrap(stats["reportsDuringWheel"] as? Int), 0,
                               "flush ごとに pageChanged を送らない")
            }
            let offset = try await harness.offset()
            XCTAssertGreaterThan(offset, 0)
        }
    }

    func testMomentumAndSmallDeltasCoalesceWhileOneJavaScriptCallIsInFlight() async throws {
        for flow in ["scrolled-doc", "scrolled-continuous"] {
            let book = try scrollPublication(flow: flow, modes: ["vertical-rl", "vertical-rl"])
            let harness = ScrolledFlowWheelHarness()
            defer { harness.close() }
            try await harness.load(book, at: book.locator(forSpineIndex: 0, progression: 0.4))
            let initial = try await harness.offset()
            _ = try await harness.reader.evaluateForTest("""
                const scroll = __washi.scrollByWheelDelta;
                let first = true;
                __washi.scrollByWheelDelta = (...args) => {
                    const result = scroll(...args);
                    if (!first) { return result; }
                    first = false;
                    return new Promise(resolve => { globalThis.__releaseWheel = () => resolve(result); });
                };
                return true;
                """)
            // 同じターンの小さい慣性イベントも閾値なしにすべて加算する。
            for _ in 0..<7 { try harness.send(dy: -1, phase: 0, momentum: 2) }
            let started = await waitUntil(timeout: .seconds(3)) { harness.reader.scrolledWheel.isInFlight }
            XCTAssertTrue(started)
            try await assertPosition(harness, initial + 7)
            let firstCall = try await harness.metrics()
            XCTAssertEqual(firstCall["nativeCalls"] as? Int, 1)
            for _ in 0..<5 { try harness.send(dy: -1, phase: 0, momentum: 2) }
            XCTAssertEqual(harness.reader.scrolledWheel.pendingDeltas, [5])
            XCTAssertFalse(harness.reader.scrolledWheel.isScheduled)
            // 保留中の JS の実行結果が返るまで、二つ目の JS を送らない。
            let pending = try await harness.metrics()
            XCTAssertEqual(pending["nativeCalls"] as? Int, 1)
            _ = try await harness.reader.evaluateForTest("globalThis.__releaseWheel(); return true;")
            await harness.drain()
            try await assertPosition(harness, initial + 12)
            let completed = try await harness.metrics()
            XCTAssertEqual(completed["nativeCalls"] as? Int, 2)
            try harness.send(dy: 12, phase: 0, momentum: 2)
            try harness.send(phase: 0, momentum: 3)
            await harness.drain()
            try await assertPosition(harness, initial)
        }
    }

    func testHorizontalWritingKeepsWheelInWebKitForBothScrolledFlows() async throws {
        for flow in ["scrolled-doc", "scrolled-continuous"] {
            let harness = ScrolledFlowWheelHarness()
            defer { harness.close() }
            try await harness.load(try scrollPublication(flow: flow, modes: ["horizontal-tb", "horizontal-tb"]))
            let initial = try await harness.offset()
            try await harness.gesture(dy: -12)
            let moved = try await harness.waitForMovement(from: initial)
            XCTAssertGreaterThan(moved, initial)
            let metrics = try await harness.metrics()
            XCTAssertGreaterThan(try XCTUnwrap(metrics["domWheels"] as? Int), 0)
            XCTAssertEqual(metrics["nativeCalls"] as? Int, 0)
            XCTAssertFalse(harness.consumedEvents.isEmpty)
            XCTAssertTrue(harness.consumedEvents.allSatisfy { !$0 })
            try await harness.gesture(dy: 12)
            let returned = try await harness.waitForMovement(from: moved)
            XCTAssertLessThan(returned, moved)
        }
    }

    func testWheelClampsAtEdgesAndExplicitNavigationStillCrossesSpineBoundaries() async throws {
        for flow in ["scrolled-doc", "scrolled-continuous"] {
            for mode in ["horizontal-tb", "vertical-rl"] {
                let continuous = flow == "scrolled-continuous"
                let book = try scrollPublication(
                    flow: continuous ? "paginated" : flow, modes: [mode, mode, mode],
                    overrides: continuous ? ["rendition:flow-scrolled-continuous",
                                              "rendition:flow-scrolled-continuous", ""] : [])
                let harness = ScrolledFlowWheelHarness()
                defer { harness.close() }
                let endIndex = continuous ? 1 : 0
                try await harness.load(book, at: book.locator(forSpineIndex: endIndex, progression: 1))
                let end = try await harness.metrics()
                let maximum = try XCTUnwrap(end["extent"] as? Double) - XCTUnwrap(end["viewport"] as? Double)
                try await harness.gesture(dy: -12)
                // WebKit の rubber band と既存の 120ms 位置通知が落ち着いてから調べる。
                try await Task.sleep(for: .milliseconds(600))
                let endPosition = try await harness.offset()
                XCTAssertEqual(max(0, min(maximum, endPosition)), maximum, accuracy: 1)
                XCTAssertEqual(harness.reader.currentSpineIndex, endIndex)
                XCTAssertTrue(harness.spy.edges.isEmpty, "ホイールは boundary を発行しない")
                harness.reader.goForward()
                let crossed = await waitUntil(timeout: .seconds(8)) {
                    harness.reader.currentSpineIndex == endIndex + 1 && !harness.reader.spineLoad.isLoadingSpineItem
                }
                XCTAssertTrue(crossed, "明示的なページ送りは既存の boundary 経路を使う")
                let moves = harness.spy.moveCount
                harness.reader.go(to: book.locator(forSpineIndex: 0))
                let returned = await waitUntil(timeout: .seconds(8)) {
                    harness.spy.moveCount > moves && harness.reader.currentSpineIndex == 0
                        && !harness.reader.spineLoad.isLoadingSpineItem
                }
                XCTAssertTrue(returned)
                try await harness.gesture(dy: 12)
                try await Task.sleep(for: .milliseconds(600))
                let startPosition = try await harness.offset()
                XCTAssertEqual(max(0, startPosition), 0, accuracy: 1)
                XCTAssertEqual(harness.reader.currentSpineIndex, 0)
                XCTAssertTrue(harness.spy.edges.isEmpty)
                harness.reader.goBackward()
                let reachedStart = await waitUntil(timeout: .seconds(3)) { harness.spy.edges == [false] }
                XCTAssertTrue(reachedStart)
                XCTAssertTrue(harness.spy.failures.isEmpty)
            }
        }
    }

    func testReloadDiscardsQueuedWheelAndRefreshesWritingMode() async throws {
        let harness = ScrolledFlowWheelHarness()
        defer { harness.close() }
        let vertical = try scrollPublication(modes: ["vertical-rl"])
        try await harness.load(vertical)
        try harness.send(dy: -100)
        try harness.sendFractional(dy: -0.5)
        XCTAssertTrue(harness.reader.scrolledWheel.isScheduled)
        XCTAssertEqual(harness.reader.scrolledWheel.pendingDeltas, [100])
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0.5)
        // 同じ縦書きへ reload しても、古い予約や端数で新しい先頭が動かない。
        try await harness.load(vertical)
        await harness.drain()
        try await assertPosition(harness, 0)
        XCTAssertTrue(harness.reader.scrolledWheel.pendingDeltas.isEmpty)
        XCTAssertEqual(harness.reader.scrolledWheel.fractionalRemainder, 0)
        let fresh = try await harness.metrics()
        XCTAssertEqual(fresh["nativeCalls"] as? Int, 0)
        try harness.send(dy: -100, phase: 1)
        XCTAssertEqual(harness.reader.scrolledWheel.pendingDeltas, [100])
        let horizontal = try scrollPublication(modes: ["horizontal-tb"])
        try await harness.load(horizontal)
        await harness.drain()
        try await assertPosition(harness, 0)
        XCTAssertEqual(harness.reader.scrolledWheel.mode, "htb")
        try await harness.gesture(dy: -12)
        let position = try await harness.waitForMovement(from: 0)
        XCTAssertGreaterThan(position, 0)
        XCTAssertTrue(harness.consumedEvents.allSatisfy { !$0 })
        let metrics = try await harness.metrics()
        XCTAssertEqual(metrics["nativeCalls"] as? Int, 0)
    }

    private func assertPosition(_ harness: ScrolledFlowWheelHarness, _ expected: Double,
                                _ message: String = "", file: StaticString = #filePath,
                                line: UInt = #line) async throws {
        let offset = try await harness.offset()
        XCTAssertEqual(offset, expected, accuracy: 1, message, file: file, line: line)
    }

    private func assertChildrenInSync(_ harness: ScrolledFlowWheelHarness,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let metrics = try await harness.metrics()
        let offset = try XCTUnwrap(metrics["offset"] as? Double)
        let viewport = try XCTUnwrap(metrics["viewport"] as? Double)
        let items = try XCTUnwrap(metrics["items"] as? [[String: Any]])
        let children = try XCTUnwrap(metrics["children"] as? [[String: Any]])
        XCTAssertEqual(items.count, children.count, file: file, line: line)
        for (item, child) in zip(items, children) {
            let start = try XCTUnwrap(item["start"] as? Double)
            let extent = try XCTUnwrap(item["extent"] as? Double)
            guard start <= offset + viewport, start + extent >= offset else { continue }
            let expected = max(0, min(extent - viewport, offset - start))
            XCTAssertEqual(try XCTUnwrap(child["offset"] as? Double), expected, accuracy: 1,
                           "可視 iframe とコンテナの位置", file: file, line: line)
            let sign = child["mode"] as? String == "vrl" ? -1.0 : 1.0
            XCTAssertEqual(try XCTUnwrap(child["scrollX"] as? Double), expected * sign, accuracy: 1,
                           file: file, line: line)
        }
    }
}
