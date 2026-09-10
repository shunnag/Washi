import Foundation
import XCTest
@testable import WashiCore

final class ExtractedTextCacheTests: XCTestCase {
    func testCombiningScalarsCannotBypassMemoryBudget() {
        let cache = ExtractedTextCache(byteLimit: 64)
        let text = "a" + String(repeating: "\u{0301}", count: 100)
        XCTAssertEqual(text.count, 1)
        XCTAssertGreaterThan(text.utf8.count, 64)
        cache.insert(text, for: 0)
        XCTAssertNil(cache.value(for: 0))
    }

    func testMultibyteTextEvictsAccordingToStorageCost() {
        let cache = ExtractedTextCache(byteLimit: 12)
        cache.insert("日本語", for: 0) // Nine UTF-8 bytes.
        cache.insert("abcd", for: 1)
        XCTAssertNil(cache.value(for: 0))
        XCTAssertEqual(cache.value(for: 1), "abcd")
    }

    func testEmptyChaptersHaveBoundedEntryCount() {
        let cache = ExtractedTextCache(byteLimit: 64, entryLimit: 2)
        for index in 0..<10 { cache.insert("", for: index) }
        for index in 0..<8 { XCTAssertNil(cache.value(for: index)) }
        XCTAssertEqual(cache.value(for: 8), "")
        XCTAssertEqual(cache.value(for: 9), "")
    }

    func testDuplicateInsertionDoesNotEvictOrChargeTwice() {
        let cache = ExtractedTextCache(byteLimit: 8)
        cache.insert("abcd", for: 0)
        cache.insert("xxxx", for: 0)
        cache.insert("efgh", for: 1)
        XCTAssertEqual(cache.value(for: 0), "abcd")
        XCTAssertEqual(cache.value(for: 1), "efgh")
    }

    func testConcurrentExtractionKeepsCacheConsistent() {
        let cache = ExtractedTextCache(byteLimit: 64, entryLimit: 8)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            cache.insert("chapter", for: index % 20)
            if let text = cache.value(for: index % 20) {
                XCTAssertEqual(text, "chapter")
            }
        }
        XCTAssertLessThanOrEqual((0..<20).compactMap { cache.value(for: $0) }.count, 8)
    }
}
