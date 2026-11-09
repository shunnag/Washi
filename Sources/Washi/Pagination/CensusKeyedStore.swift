import Foundation

/// メトリクスキーごとの census の値(完走した結果、または中断した実測の
/// 先頭部分)を、件数と概算バイト数の両方で制限する。上限を超えたら挿入順
/// (FIFO)で追い出す。表示中のキーは追い出さない: 中断した実測の先頭部分は、
/// そのキーで次に実測するときに続きから測るための唯一の手がかりで、現在の
/// キーの分が消えると最初から測り直すことになる。
struct CensusKeyedStore<Value> {
    static var defaultLimit: Int { 16 }
    static var defaultByteLimit: Int { 4 * 1_024 * 1_024 }

    private var values: [String: Value] = [:]
    private var recordBytes: [String: Int] = [:]
    /// 挿入順(先頭が最古)。ヒットでは並べ替えない
    private var insertionOrder: [String] = []
    let limit: Int
    let byteLimit: Int
    private let valueByteCount: (Value) -> Int
    /// キーの UTF-8 と値の可変部分の概算。固定のDictionary等の費用は件数で制限する。
    private(set) var estimatedByteCount = 0

    init(limit: Int = CensusKeyedStore.defaultLimit,
         byteLimit: Int = CensusKeyedStore.defaultByteLimit,
         valueByteCount: @escaping (Value) -> Int) {
        self.limit = max(1, limit)
        self.byteLimit = max(1, byteLimit)
        self.valueByteCount = valueByteCount
    }

    var count: Int { insertionOrder.count }
    var keys: Set<String> { Set(insertionOrder) }

    subscript(key: String) -> Value? { values[key] }

    /// 値を入れる。上限に達していれば `currentKey` 以外の最古のキーから追い出す。
    /// 単一レコードが予算を超える場合や、保護中のキーを残すと収まらない場合は
    /// 状態を変えずに false を返す。
    @discardableResult
    mutating func insert(_ value: Value, forKey key: String,
                         protecting currentKey: String?) -> Bool {
        let (newRecordBytes, overflow) = key.utf8.count.addingReportingOverflow(
            valueByteCount(value))
        guard !overflow, newRecordBytes <= byteLimit else { return false }
        if let currentKey, currentKey != key, values[currentKey] != nil {
            // 先に他のキーを追い出してから保存不能と判明する、部分的な更新を避ける。
            guard limit > 1 || values[key] != nil,
                  newRecordBytes + (recordBytes[currentKey] ?? 0) <= byteLimit
            else { return false }
        }
        var projectedBytes = estimatedByteCount - (recordBytes[key] ?? 0) + newRecordBytes
        if values[key] == nil {
            while !insertionOrder.isEmpty,
                  insertionOrder.count >= limit || projectedBytes > byteLimit {
                guard let victim = insertionOrder.firstIndex(where: { $0 != currentKey })
                else { return false }
                projectedBytes -= removeEntry(at: victim)
            }
            guard insertionOrder.count < limit, projectedBytes <= byteLimit else { return false }
            insertionOrder.append(key)
        } else {
            while projectedBytes > byteLimit {
                guard let victim = insertionOrder.firstIndex(where: {
                    $0 != currentKey && $0 != key
                }) else { return false }
                projectedBytes -= removeEntry(at: victim)
            }
        }
        estimatedByteCount = projectedBytes
        recordBytes[key] = newRecordBytes
        values[key] = value
        return true
    }

    mutating func removeValue(forKey key: String) {
        guard let index = insertionOrder.firstIndex(of: key) else { return }
        _ = removeEntry(at: index)
    }

    mutating func removeAll() {
        values.removeAll()
        recordBytes.removeAll()
        insertionOrder.removeAll()
        estimatedByteCount = 0
    }

    private mutating func removeEntry(at index: Int) -> Int {
        let key = insertionOrder.remove(at: index)
        values[key] = nil
        let bytes = recordBytes.removeValue(forKey: key) ?? 0
        estimatedByteCount -= bytes
        return bytes
    }
}

extension CensusKeyedStore where Value == [Int] {
    init(limit: Int = CensusKeyedStore.defaultLimit,
         byteLimit: Int = CensusKeyedStore.defaultByteLimit) {
        self.init(limit: limit, byteLimit: byteLimit) {
            $0.count * MemoryLayout<Int>.stride
        }
    }
}
