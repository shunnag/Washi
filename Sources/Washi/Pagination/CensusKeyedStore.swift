import Foundation

/// メトリクスキーごとの census の値(完走した結果、または中断した実測の
/// 先頭部分)を、上限付きで保持する。上限を超えたら挿入順(FIFO)で追い出す
/// (EPUBScreenAtlas の countsCache と同じ方針。大きな userCSS を含むキーが
/// セッション中に無限に溜まるのを防ぐ)。表示中のキーは追い出さない:
/// 中断した実測の先頭部分は、そのキーで次に実測するときに続きから測るための
/// 唯一の手がかりで、現在のキーの分が消えると最初から測り直すことになる。
struct CensusKeyedStore<Value> {
    static var defaultLimit: Int { 16 }

    private var values: [String: Value] = [:]
    /// 挿入順(先頭が最古)。ヒットでは並べ替えない
    private var insertionOrder: [String] = []
    let limit: Int

    init(limit: Int = CensusKeyedStore.defaultLimit) {
        self.limit = max(1, limit)
    }

    var count: Int { insertionOrder.count }
    var keys: Set<String> { Set(insertionOrder) }

    subscript(key: String) -> Value? { values[key] }

    /// 値を入れる。新しいキーで上限に達していれば、`currentKey` 以外の最古の
    /// キーから追い出す(追い出せるキーがなければ上限を一時的に 1 超える)
    mutating func insert(_ value: Value, forKey key: String, protecting currentKey: String?) {
        if values[key] == nil {
            while insertionOrder.count >= limit,
                  let victim = insertionOrder.firstIndex(where: { $0 != currentKey }) {
                values[insertionOrder.remove(at: victim)] = nil
            }
            insertionOrder.append(key)
        }
        values[key] = value
    }

    mutating func removeValue(forKey key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        insertionOrder.removeAll { $0 == key }
    }
}
