import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// census の所要時間を公開コーパスで測る opt-in のハーネス。
/// WASHI_CENSUS_BENCH_OUT / WASHI_CORPUS_DIR を必須とする。
/// WASHI_CENSUS_COMPARE=1 で serial と RAM 予算内の適応的 pool を同じ本・倍率で比較し、
/// 項目別 counts の一致を検証する。このモードは FXL 本も含める。
/// WASHI_BENCH_SCALES=0.8,1.25,2.0 / WASHI_BENCH_REPETITIONS=2 で倍率・反復を指定。
/// WASHI_BENCH_BOOKS / WASHI_BENCH_SPINE は冊数・spine の上限(既定 25 / 60)、
/// WASHI_BENCH_FILTER は相対パスの部分一致(カンマ区切り)。旧 WASHI_BENCH_SCALE も使える。
/// WASHI_BENCH_PROCESS_CHECK=1 は全 WebContent の PID/RSS を前・保持中・close 後に記録し、
/// 10 秒後にも残る新規 PID は参考情報として出力する(他のアプリのプロセスも含む)。
@MainActor
final class CensusTimingHarnessTests: XCTestCase {
    private static var maximumBooks: Int {
        Int(ProcessInfo.processInfo.environment["WASHI_BENCH_BOOKS"] ?? "") ?? 25
    }
    private static var maximumSpineItems: Int {
        Int(ProcessInfo.processInfo.environment["WASHI_BENCH_SPINE"] ?? "") ?? 60
    }

    func testCensusTimingOverCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["WASHI_CENSUS_BENCH_OUT"], !outputPath.isEmpty else {
            throw XCTSkip("WASHI_CENSUS_BENCH_OUT が未設定です")
        }
        guard let corpusPath = environment["WASHI_CORPUS_DIR"], !corpusPath.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR が未設定です")
        }
        let root = URL(fileURLWithPath: corpusPath, isDirectory: true).standardizedFileURL
        let books = Self.corpusBooks(in: root)
        guard !books.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR にリフローの EPUB がありません: \(root.path)")
        }

        let scales = (environment["WASHI_BENCH_SCALES"] ?? environment["WASHI_BENCH_SCALE"] ?? "1")
            .split(separator: ",").compactMap { Double($0) }
        XCTAssertFalse(scales.isEmpty)
        let repetitions = max(1, Int(environment["WASHI_BENCH_REPETITIONS"] ?? "") ?? 1)
        let comparing = environment["WASHI_CENSUS_COMPARE"] == "1"
        let checkingProcesses = environment["WASHI_BENCH_PROCESS_CHECK"] == "1"
        let variants: [(name: String, maximumWorkers: Int)] = comparing
            ? [("serial", 1), ("pool", 4)] : [("pool", 4)]
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let warmupMetrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 800, height: 600), settings: settings)
        // ウォームアップ: WebContent プロセスの起動と初回 JIT を計測から外す
        let warmup = EPUBPaginationCensus()
        let tiny = try Self.tinyBook()
        let warmed = await Task(priority: .userInitiated) {
            await warmup.measure(publication: tiny, optionsJSON: warmupMetrics.censusOptionsJSON, contentSize: warmupMetrics.contentSize)
        }.value
        warmup.invalidate()
        guard warmed != nil else { return try failOrSkipIfWebKitUnavailable() }

        let output = URL(fileURLWithPath: outputPath)
        try Data().write(to: output)  // 前回の出力を残さない
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var total = Duration.zero
        for (url, name) in books {
            for scale in scales {
                settings.fontScale = scale
                let metrics = EPUBScreenMetrics(
                    viewportSize: CGSize(width: 800, height: 600), settings: settings)
                var baseline: [Int]?
                for round in 0..<repetitions {
                    // 初回は serial を基準にし、以後は順を交互にしてキャッシュ差を観測する。
                    let ordered = round.isMultiple(of: 2) ? variants : Array(variants.reversed())
                    for variant in ordered {
                        let publication = try EPUBPublication(url: url, readStrategy: .alwaysCopy)
                        let census = EPUBPaginationCensus(maximumWorkers: variant.maximumWorkers)
                        let before = checkingProcesses ? try Self.webContentProcesses() : [:]
                        let start = ContinuousClock.now
                        let outcome = await census.measure(
                            publication: publication, optionsJSON: metrics.censusOptionsJSON,
                            contentSize: metrics.contentSize, resuming: [])
                        let elapsed = ContinuousClock.now - start
                        let loadedProcesses = checkingProcesses ? try Self.webContentProcesses() : [:]
                        census.invalidate()
                        XCTAssertEqual(census.liveWebViewCount, 0, "\(name): close 後にホストが残っています")
                        let afterClose = checkingProcesses
                            ? try await Self.waitForWebContentExit(baseline: Set(before.keys)) : [:]
                        let newPIDs = Set(afterClose.keys).subtracting(before.keys).sorted()
                        if !newPIDs.isEmpty {
                            print("[Washi census bench] 参考: \(name) close 後のシステム全体の新規 WebContent PID: \(newPIDs)")
                        }
                        total += elapsed
                        let seconds = Double(elapsed.components.seconds)
                            + Double(elapsed.components.attoseconds) / 1e18
                        XCTAssertTrue(outcome.isComplete, "\(name): \(variant.name) census が完走しません")
                        if baseline == nil { baseline = outcome.counts }
                        XCTAssertEqual(outcome.counts, baseline,
                                       "\(name) scale=\(scale) \(variant.name): serial と counts が異なります")
                        let record: [String: Any] = [
                            "book": name, "variant": variant.name, "round": round, "fontScale": scale,
                            "spineItems": publication.readingOrder.count,
                            "counts": outcome.counts, "pages": outcome.counts.reduce(0, +),
                            "complete": outcome.isComplete, "seconds": seconds,
                            "workers": census.lastWorkerCount, "countsMatchSerial": outcome.counts == baseline,
                            "liveHostsAfterClose": census.liveWebViewCount,
                            "newWebContentPIDsAfterClose": newPIDs,
                            "webContentBefore": Self.processRecords(before),
                            "webContentLoaded": Self.processRecords(loadedProcesses),
                            "webContentAfterClose": Self.processRecords(afterClose),
                        ]
                        let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                        try handle.write(contentsOf: line + Data("\n".utf8))
                        print("[Washi census bench] \(name) \(variant.name) k=\(census.lastWorkerCount) "
                              + "scale=\(scale) pages=\(outcome.counts.reduce(0, +)) "
                              + String(format: "%.3f s", seconds))
                    }
                }
            }
        }
        print("[Washi census bench] 合計 \(books.count) 冊 / \(total)")
    }

    private static func webContentProcesses() throws -> [Int: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        var result: [Int: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("WebContent") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            if fields.count == 3, let pid = Int(fields[0]), let rss = Int(fields[1]) { result[pid] = rss }
        }
        return result
    }

    private static func waitForWebContentExit(baseline: Set<Int>) async throws -> [Int: Int] {
        let deadline = ContinuousClock.now + .seconds(10)
        var processes = try webContentProcesses()
        while !Set(processes.keys).subtracting(baseline).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            processes = try webContentProcesses()
        }
        return processes
    }

    private static func processRecords(_ processes: [Int: Int]) -> [[String: Int]] {
        processes.sorted { $0.key < $1.key }.map { ["pid": $0.key, "rssKiB": $0.value] }
    }

    /// パス順に走査し、開けて spine が上限以下でリフロー項目を含む本を先頭から
    /// `maximumBooks` 冊選ぶ(選択は決定的)。名前はコーパス直下からの相対パス
    private static func corpusBooks(in root: URL) -> [(URL, String)] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "epub" { urls.append(url.standardizedFileURL) }
        }
        var books: [(URL, String)] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard books.count < maximumBooks,
                  let publication = try? EPUBPublication(url: url, readStrategy: .alwaysCopy),
                  (1...maximumSpineItems).contains(publication.readingOrder.count),
                  (ProcessInfo.processInfo.environment["WASHI_CENSUS_COMPARE"] == "1"
                   || publication.readingOrder.contains(where: {
                       publication.package.effectiveLayout(for: $0.itemRef) != .prePaginated
                   }))
            else { continue }
            let name = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            if let filter = ProcessInfo.processInfo.environment["WASHI_BENCH_FILTER"],
               !filter.split(separator: ",").contains(where: { name.contains($0) }) { continue }
            books.append((url, name))
        }
        return books
    }

    /// ウォームアップ用の最小リフロー本(spine 1 項目)
    private static func tinyBook() throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:census-bench-warmup</dc:identifier>
                <dc:title>Warmup</dc:title><dc:language>ja</dc:language>
              </metadata>
              <manifest>
                <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
            <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """.utf8)),
            ("book.opf", Data(opf.utf8)),
            ("c.xhtml", Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>warmup</title></head>
            <body><p>\(String(repeating: "本文。", count: 400))</p></body></html>
            """.utf8)),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-census-bench-warmup.epub"))
    }
}
