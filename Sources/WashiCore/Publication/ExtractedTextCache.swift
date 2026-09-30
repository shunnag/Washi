import Foundation

// cooViewer-oxr.67 / cooViewer-oxr.71: 本文抽出結果を spine 単位で再利用する。
// EPUBPublication は Sendable のため、可変状態は NSLock の内側だけで扱う。
final class ExtractedTextCache: @unchecked Sendable {
    private struct Entry {
        let text: String
        let byteCount: Int
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let entryLimit: Int
    private var entries: [Int: Entry] = [:]
    private var insertionOrder: [Int] = []
    private var insertionHead = 0
    private var totalByteCount = 0

    init(byteLimit: Int, entryLimit: Int = 512) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }

    func value(for spineIndex: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[spineIndex]?.text
    }

    func insert(_ text: String, for spineIndex: Int) {
        // 結合文字列は文字数だけでは保持メモリを制限できないため、UTF-8 の
        // バイト数で数える。空章については別途、管理件数にも上限を設ける。
        let byteCount = text.utf8.count
        guard byteCount <= byteLimit, entryLimit > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard entries[spineIndex] == nil else { return }
        while (byteCount > byteLimit - totalByteCount || entries.count >= entryLimit),
              insertionHead < insertionOrder.count {
            let oldest = insertionOrder[insertionHead]
            insertionHead += 1
            if let removed = entries.removeValue(forKey: oldest) {
                totalByteCount -= removed.byteCount
            }
        }
        entries[spineIndex] = Entry(text: text, byteCount: byteCount)
        insertionOrder.append(spineIndex)
        totalByteCount += byteCount
        // 追い出すたびに全添字をずらさず、消費済みの部分をまとめて回収する。
        // 未回収の添字数も生存件数以下に保ち、FIFO 順とメモリ上限を維持する。
        if insertionHead >= entries.count {
            insertionOrder.removeFirst(insertionHead)
            insertionHead = 0
        }
    }
}

extension EPUBPublication {
    /// cooViewer-oxr.67 / cooViewer-oxr.71: 本文抽出・検索・概算ページ数の共有経路。
    func cachedExtractedText(forSpineIndex index: Int,
                             loader: () throws -> String) rethrows -> String {
        if let cached = extractedTextCache.value(for: index) { return cached }
        let text = try loader()
        extractedTextCache.insert(text, for: index)
        return text
    }
}
