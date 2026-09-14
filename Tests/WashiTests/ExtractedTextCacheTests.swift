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

    /// 多数回の追い出し後も FIFO 順を維持し、大きな項目のために複数件を
    /// 回収した後は残存項目のバイト数を正しく数える。
    func testRepeatedEvictionAndLargerReplacementPreserveFIFOAndBudget() {
        let cache = ExtractedTextCache(byteLimit: 32, entryLimit: 8)
        for index in 0..<64 {
            cache.insert("text", for: index)
            for retained in max(0, index - 7)...index {
                XCTAssertEqual(cache.value(for: retained), "text")
            }
            if index >= 8 { XCTAssertNil(cache.value(for: index - 8)) }
        }

        let larger = String(repeating: "x", count: 20)
        cache.insert(larger, for: 100)
        for evicted in 56..<61 { XCTAssertNil(cache.value(for: evicted)) }
        for retained in 61..<64 { XCTAssertEqual(cache.value(for: retained), "text") }
        XCTAssertEqual(cache.value(for: 100), larger)

        cache.insert("next", for: 101)
        XCTAssertNil(cache.value(for: 61))
        XCTAssertEqual(cache.value(for: 62), "text")
        XCTAssertEqual(cache.value(for: 63), "text")
        XCTAssertEqual(cache.value(for: 100), larger)
        XCTAssertEqual(cache.value(for: 101), "next")
    }
}
