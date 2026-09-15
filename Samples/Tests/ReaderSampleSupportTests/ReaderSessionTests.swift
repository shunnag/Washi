import AppKit
import SwiftUI
import XCTest
import Washi
@testable import ReaderSampleSupport

private actor ControlledOpen {
    private var requests: [URL: CheckedContinuation<EPUBPublication, any Error>] = [:]
    func open(_ url: URL) async throws -> EPUBPublication {
        try await withCheckedThrowingContinuation { requests[url] = $0 }
    }
    func contains(_ url: URL) -> Bool { requests[url] != nil }
    func finish(_ url: URL, with publication: EPUBPublication) {
        requests.removeValue(forKey: url)?.resume(returning: publication)
    }
}

@MainActor
final class ReaderSessionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "org.washi.samples.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    func testOlderOpenCannotReplaceNewBook() async throws {
        let gate = ControlledOpen()
        let session = ReaderSession(defaults: defaults, opener: { try await gate.open($0) })
        defer { session.close() }
        let firstURL = URL(fileURLWithPath: "/first.epub")
        let secondURL = URL(fileURLWithPath: "/second.epub")
        let first = try EPUBPublication(url: ReaderSession.demoURL)
        let second = try EPUBPublication(url: ReaderSession.demoURL)
        session.open(firstURL)
        let firstStarted = await waitUntil { await gate.contains(firstURL) }
        XCTAssertTrue(firstStarted)
        session.open(secondURL)
        let secondStarted = await waitUntil { await gate.contains(secondURL) }
        XCTAssertTrue(secondStarted)
        await gate.finish(secondURL, with: second)
        let newestLoaded = await waitUntil { session.reader.publication === second }
        XCTAssertTrue(newestLoaded)
        await gate.finish(firstURL, with: first)
        // 古い要求の完了を main actor に処理させてから、出版物の同一性を確認する。
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(session.reader.publication === second)
    }

    func testCloseWhileOpeningDiscardsCompletion() async throws {
        let gate = ControlledOpen()
        let session = ReaderSession(defaults: defaults, opener: { try await gate.open($0) })
        let url = ReaderSession.demoURL
        session.open(url)
        let started = await waitUntil { await gate.contains(url) }
        XCTAssertTrue(started)
        session.close()
        await gate.finish(url, with: try EPUBPublication(url: url))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.reader.publication)
    }

    func testOpenAndRenderingFailuresReachState() async {
        let session = ReaderSession(defaults: defaults, opener: { _ in throw EPUBError.malformed("sample failure") })
        defer { session.close() }
        session.open(ReaderSession.demoURL)
        let failed = await waitUntil { session.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(session.errorMessage?.contains("sample failure") == true)
        session.readerView(session.reader, didFailWith: EPUBError.resourceNotFound("chapter.xhtml"))
        XCTAssertTrue(session.errorMessage?.contains("chapter.xhtml") == true)
    }

    func testAppKitDisplaySearchRestoreAndClose() async throws {
        try await exerciseReader(swiftUI: false)
    }

    func testSwiftUIDisplaySearchRestoreAndClose() async throws {
        try await exerciseReader(swiftUI: true)
    }

    private func exerciseReader(swiftUI: Bool) async throws {
        let session = ReaderSession(defaults: defaults, opener: { try await EPUBPublication.open(url: $0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if swiftUI {
            window.contentViewController = NSHostingController(
                rootView: ReaderSurface(session: session).frame(minWidth: 800, minHeight: 600))
        } else {
            window.contentView = session.reader
        }
        window.makeKeyAndOrderFront(nil)
        defer { session.close(); window.close() }
        session.open(ReaderSession.demoURL)
        let ready = await waitUntil { session.phase == .ready }
        XCTAssertTrue(ready, session.status)
        guard ready else { return }
        XCTAssertEqual(session.reader.currentSpineIndex, 0)
        session.search("和紙")
        let found = await waitUntil { !session.isSearching }
        XCTAssertTrue(found)
        let last = try XCTUnwrap(session.hits.indices.last)
        XCTAssertEqual(session.hits[last].spineIndex, 1)
        session.showHit(at: last)
        let moved = await waitUntil { session.position.hasPrefix("章 2") }
        XCTAssertTrue(moved, session.status)
        XCTAssertEqual(session.reader.highlights.count, 1)
        let snapshot = try await session.reader.snapshot()
        XCTAssertGreaterThan(snapshot.size.width, 0)
        session.close()
        XCTAssertNil(session.reader.publication)
        session.open(ReaderSession.demoURL)
        let restored = await waitUntil { session.phase == .ready && session.position.hasPrefix("章 2") }
        XCTAssertTrue(restored, session.status)
        session.search("和紙")
        session.close()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(session.isSearching)
        XCTAssertTrue(session.hits.isEmpty)
        XCTAssertEqual(session.phase, .idle)
    }
}
