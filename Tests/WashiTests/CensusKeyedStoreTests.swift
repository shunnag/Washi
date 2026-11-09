import XCTest
@testable import Washi

/// census の上限付きキー別ストア(完走結果と中断控えの両方で使う)の検証。
final class CensusKeyedStoreTests: XCTestCase {
    func testEvictsOldestNonCurrentKeyAtLimit() {
        var store = CensusKeyedStore<[Int]>(limit: 3)
        store.insert([1], forKey: "current", protecting: "current")
        store.insert([2], forKey: "a", protecting: "current")
        store.insert([3], forKey: "b", protecting: "current")
        XCTAssertEqual(store.count, 3)

        // 最古は current だが、表示中のキーは追い出さず次に古い a を追い出す
        store.insert([4], forKey: "c", protecting: "current")
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.keys, ["current", "b", "c"])
        XCTAssertEqual(store["current"], [1])

        // 表示中のキーが替われば、以前のキーも FIFO の対象に戻る
        store.insert([5], forKey: "d", protecting: "c")
        XCTAssertEqual(store.keys, ["b", "c", "d"])
    }

    func testBoundHoldsOverManyInsertions() {
        var store = CensusKeyedStore<[Int]>()
        store.insert([0], forKey: "current", protecting: "current")
        for index in 1..<100 {
            store.insert([index], forKey: "k\(index)", protecting: "current")
            XCTAssertLessThanOrEqual(store.count, CensusKeyedStore<[Int]>.defaultLimit)
            XCTAssertEqual(store["current"], [0])
        }
        XCTAssertEqual(store.count, 16)
    }

    func testReinsertingExistingKeyReplacesValueWithoutEviction() {
        var store = CensusKeyedStore<[Int]>(limit: 2)
        store.insert([1], forKey: "a", protecting: nil)
        store.insert([2], forKey: "b", protecting: nil)
        store.insert([1, 1], forKey: "a", protecting: nil)
        XCTAssertEqual(store.keys, ["a", "b"])
        XCTAssertEqual(store["a"], [1, 1])

        // 更新は挿入順を変えない: 次の新規キーで最古の a が出る
        store.insert([3], forKey: "c", protecting: nil)
        XCTAssertEqual(store.keys, ["b", "c"])
    }

    func testRemoveFreesSlot() {
        var store = CensusKeyedStore<[Int]>(limit: 2)
        store.insert([1], forKey: "a", protecting: nil)
        store.insert([2], forKey: "b", protecting: nil)
        store.removeValue(forKey: "a")
        store.removeValue(forKey: "missing")
        XCTAssertEqual(store.keys, ["b"])
        store.insert([3], forKey: "c", protecting: nil)
        XCTAssertEqual(store.keys, ["b", "c"])
    }

    func testByteBudgetEvictsOldRecordsAndRejectsOversizedRecord() {
        var store = CensusKeyedStore<[Int]>(limit: 3, byteLimit: 24)
        XCTAssertTrue(store.insert([1, 1], forKey: "a", protecting: nil))
        XCTAssertEqual(store.estimatedByteCount, 17)

        XCTAssertTrue(store.insert([2], forKey: "b", protecting: nil))
        XCTAssertEqual(store.keys, ["b"])
        XCTAssertEqual(store.estimatedByteCount, 9)

        let hugeKey = String(repeating: "x", count: 1_024)
        XCTAssertFalse(store.insert([3], forKey: hugeKey, protecting: nil))
        XCTAssertEqual(store.keys, ["b"])
        XCTAssertEqual(store["b"], [2])
        XCTAssertEqual(store.estimatedByteCount, 9)
    }

    func testRejectedInsertionDoesNotPartiallyEvictExistingRecords() {
        var store = CensusKeyedStore<[Int]>(limit: 3, byteLimit: 36)
        store.insert([1, 1], forKey: "current", protecting: nil)
        store.insert([2], forKey: "other", protecting: nil)
        XCTAssertEqual(store.estimatedByteCount, 36)

        XCTAssertFalse(store.insert([3, 3, 3], forKey: "new", protecting: "current"))
        XCTAssertEqual(store.keys, ["current", "other"])
        XCTAssertEqual(store["other"], [2])
        XCTAssertEqual(store.estimatedByteCount, 36)
    }

    func testReplacementAndRemovalKeepByteAccountingExact() {
        var store = CensusKeyedStore<[Int]>(limit: 2, byteLimit: 40)
        store.insert([1], forKey: "a", protecting: nil)
        store.insert([2, 2], forKey: "b", protecting: nil)
        XCTAssertEqual(store.estimatedByteCount, 26)

        XCTAssertTrue(store.insert([1, 1, 1], forKey: "a", protecting: nil))
        XCTAssertEqual(store.estimatedByteCount, 25)
        XCTAssertEqual(store.keys, ["a"])
        store.removeValue(forKey: "a")
        XCTAssertEqual(store.estimatedByteCount, 0)
        store.removeAll()
        XCTAssertEqual(store.count, 0)
    }
}
