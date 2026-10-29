import Foundation
import XCTest
@testable import Washi
@testable import WashiCore

/// 公開コーパスのリフロー本で、中断して続きから測った census が中断なしの census と
/// 同一になることを確かめる(CorpusSmokeTests と同じく WASHI_CORPUS_DIR が
/// 設定されているときだけ走る)。本ごとに 3 つの新しいエンジンを使う:
/// 一気に測る → 読み込み項目の半分ほどで invalidate して止める → 控えから再開。
@MainActor
final class CensusResumeCorpusTests: XCTestCase {
    private static let maximumBooks = 20
    private static let maximumSpineItems = 40

    func testInterruptedAndResumedCensusMatchesUninterruptedCensus() async throws {
        let root = try Self.corpusDirectory()
        let books = Self.reflowableBooks(in: root)
        guard !books.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR にリフローの EPUB がありません: \(root.path)")
        }
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 800, height: 600), settings: settings)
        let key = metrics.censusOptionsJSON
        let suiteStart = ContinuousClock.now
        var passed = 0

        for (publication, name) in books {
            let bookStart = ContinuousClock.now
            let reference = EPUBPaginationCensus(maximumWorkers: 1)
            let full = await reference.measure(
                publication: publication, optionsJSON: key, contentSize: metrics.contentSize)
            reference.invalidate()
            let loaded = reference.loadedItemCount
            guard let full else {
                XCTFail("\(name): 中断なしの census が完走しません(読み込み \(loaded) 項目)")
                continue
            }

            // 読み込む項目の半分ほどを測り終えたところで止める。
            let trigger = TriggeringSetupScheduler()
            trigger.triggerAtScheduleCount = loaded >= 2 ? loaded / 2 + 1 : 1
            let interrupter = EPUBPaginationCensus(javaScriptTimeoutScheduler: trigger.scheduler)
            trigger.onTrigger = { [weak interrupter] in interrupter?.invalidate() }
            let interrupted = await interrupter.measure(
                publication: publication, optionsJSON: key,
                contentSize: metrics.contentSize, resuming: [])
            interrupter.invalidate()

            let resumer = EPUBPaginationCensus()
            let resumed = await resumer.measure(
                publication: publication, optionsJSON: key,
                contentSize: metrics.contentSize, resuming: interrupted.counts)
            resumer.invalidate()

            let elapsed = ContinuousClock.now - bookStart
            let prefixMatches = interrupted.counts == Array(full.prefix(interrupted.counts.count))
            let identical = resumed == EPUBPaginationCensus.Outcome(counts: full, isComplete: true)
            // 並列計測では、setup を呼んだ回数と保存できる連続 prefix 長は一致しない。
            let skippedLoads = publication.readingOrder.prefix(interrupted.counts.count).filter {
                (publication.package.effectiveLayout(for: $0.itemRef) != .prePaginated
                 || EPUBScreenMetrics.isScrolled(publication.renderingFlow(at: $0.spineIndex)))
                    && publication.resourceExists(at: $0.resolvedContainerPath)
            }.count
            let expectedResumeLoads = loaded - skippedLoads
            XCTAssertFalse(interrupted.isComplete, "\(name): 中断が起きませんでした")
            XCTAssertTrue(prefixMatches,
                          "\(name): 中断時の先頭部分 \(interrupted.counts) が \(full) の先頭と一致しません")
            XCTAssertTrue(identical,
                          "\(name): 再開後 \(resumed.counts)(完走 \(resumed.isComplete)) ≠ 中断なし \(full)")
            XCTAssertEqual(resumer.loadedItemCount, expectedResumeLoads,
                           "\(name): 再開が残りの項目だけを読み込んでいません")
            let ok = !interrupted.isComplete && prefixMatches && identical
                && resumer.loadedItemCount == expectedResumeLoads
            if ok { passed += 1 }
            print("[Washi census resume] \(ok ? "PASS" : "FAIL") \(name): "
                  + "spine \(full.count) 項目 / 読み込み \(loaded) / 中断時 \(interrupted.counts.count) 項目 / "
                  + "再開で \(resumer.loadedItemCount) 読み込み / \(elapsed)")
        }
        print("[Washi census resume] 合計 \(books.count) 冊、成功 \(passed) 冊、"
              + "\(ContinuousClock.now - suiteStart)")
    }

    private static func corpusDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["WASHI_CORPUS_DIR"],
              !path.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR が未設定です")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("WASHI_CORPUS_DIR が存在しません: \(url.path)")
        }
        return url
    }

    /// パス順に走査し、開けて spine が上限以下でリフロー項目を含む本を先頭から
    /// `maximumBooks` 冊選ぶ(選択は決定的)。
    private static func reflowableBooks(in root: URL) -> [(EPUBPublication, String)] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "epub" { urls.append(url.standardizedFileURL) }
        }
        var books: [(EPUBPublication, String)] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard books.count < maximumBooks,
                  let publication = try? EPUBPublication(url: url),
                  (1...maximumSpineItems).contains(publication.readingOrder.count),
                  publication.readingOrder.contains(where: {
                      publication.package.effectiveLayout(for: $0.itemRef) != .prePaginated
                  })
            else { continue }
            books.append((publication, url.deletingPathExtension().lastPathComponent))
        }
        return books
    }
}
