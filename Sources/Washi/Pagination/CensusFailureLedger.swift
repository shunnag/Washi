import CryptoKit
import Foundation

/// メトリクスキーごとの census 実測失敗の台帳(2-strike + TTL)。
///
/// 一時的な WebContent プロセス死・15 秒タイムアウトが同一メトリクスで 2 回
/// 起きると、そのキーの再実測を止めて runSetup のたびに 15 秒待つのを防ぐ。
/// ただし恒久停止にはしない: 稀な一過性要因(メモリ逼迫等)で 2 回失敗した
/// キーがセッション中ずっと欠けたまま(N/M・ページバーが出ない)にならない
/// よう、TTL 経過で勘定ごと赦して再挑戦させる。壊れた spine は再び 2 回失敗して
/// 戻るだけで、期限内のタイムアウト・ループ護持は保たれる。
/// 記録数には上限があり、古いものから追い出す。userCSS を含むキーはダイジェスト
/// だけを保持し、巨大な文字列が台帳に残らないようにする。
struct CensusFailureLedger {
    static var defaultLimit: Int { 64 }

    private struct Record {
        var count = 0
        /// 恒久記録(strikeLimit 回失敗)へ昇格した時刻。ttl 経過で赦す
        var permanentAt: ContinuousClock.Instant?
    }
    private var records: [String: Record] = [:]
    private var insertionOrder: [String] = []
    let ttl: Duration
    let limit: Int
    let strikeLimit = 2

    init(ttl: Duration = .seconds(300), limit: Int = CensusFailureLedger.defaultLimit) {
        self.ttl = ttl
        self.limit = max(1, limit)
    }

    var count: Int { records.count }
    var retainedKeyByteCount: Int {
        records.keys.reduce(0) { $0 + $1.utf8.count }
    }

    /// 恒久記録済みで期限内なら true(再スケジュールしない)。期限切れは赦す
    mutating func shouldSkip(_ key: String,
                             now: ContinuousClock.Instant = .now) -> Bool {
        let storageKey = Self.storageKey(for: key)
        guard let record = records[storageKey], let at = record.permanentAt else { return false }
        if now - at >= ttl {
            removeRecord(forKey: storageKey)
            return false
        }
        return true
    }

    mutating func recordFailure(_ key: String,
                                now: ContinuousClock.Instant = .now) {
        let storageKey = Self.storageKey(for: key)
        var record = records[storageKey] ?? Record()
        record.count += 1
        if record.count >= strikeLimit, record.permanentAt == nil {
            record.permanentAt = now
        }
        if records[storageKey] == nil {
            while records.count >= limit, let oldest = insertionOrder.first {
                removeRecord(forKey: oldest)
            }
            insertionOrder.append(storageKey)
        }
        records[storageKey] = record
    }

    mutating func clear() {
        records.removeAll()
        insertionOrder.removeAll()
    }

    private static func storageKey(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func removeRecord(forKey storageKey: String) {
        records[storageKey] = nil
        insertionOrder.removeAll { $0 == storageKey }
    }
}
