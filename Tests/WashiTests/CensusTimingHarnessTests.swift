import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// census の所要時間を公開コーパスで測る opt-in のハーネス(A/B 比較用)。
/// `WASHI_CENSUS_BENCH_OUT` が設定されているときだけ走り、`WASHI_CORPUS_DIR` の
/// リフロー本(spine 60 項目以下、パス順の先頭 25 冊)を本ごとに新しい
/// EPUBPaginationCensus で測り、1 冊 1 行の JSON `{book, spineItems, counts, seconds}` を
/// 出力ファイルへ書く(開始時に空にする)。本は NAS 上の本を開くホストと同じ
/// `.alwaysCopy` で開く。比較側(基準ブランチ)へそのまま写せるよう、この
/// ファイル以外の新しい記号には依存しない。
/// 全冊や大きな本の比較は WASHI_BENCH_BOOKS / WASHI_BENCH_SPINE、倍率は
/// WASHI_BENCH_SCALE、名前の絞り込みは WASHI_BENCH_FILTER(カンマ区切り)で指定する。
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
        let books = Self.reflowableBooks(in: root)
        guard !books.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR にリフローの EPUB がありません: \(root.path)")
        }

        var settings = EPUBReaderSettings()
        settings.insets = .zero
        settings.fontScale = Double(environment["WASHI_BENCH_SCALE"] ?? "1") ?? 1
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 800, height: 600), settings: settings)
        let key = metrics.censusOptionsJSON

        // ウォームアップ: WebContent プロセスの起動と初回 JIT を計測から外す
        let warmup = EPUBPaginationCensus()
        let tiny = try Self.tinyBook()
        let warmed = await Task(priority: .userInitiated) {
            await warmup.measure(publication: tiny, optionsJSON: key, contentSize: metrics.contentSize)
        }.value
        warmup.invalidate()
        guard warmed != nil else { return try failOrSkipIfWebKitUnavailable() }

        let output = URL(fileURLWithPath: outputPath)
        try Data().write(to: output)  // 前回の出力を残さない
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var total = Duration.zero
        for (url, name) in books {
            guard let publication = try? EPUBPublication(url: url, readStrategy: .alwaysCopy)
            else { continue }
            let census = EPUBPaginationCensus()
            let start = ContinuousClock.now
            let counts = await Task(priority: .userInitiated) {
                await census.measure(publication: publication, optionsJSON: key, contentSize: metrics.contentSize)
            }.value
            let elapsed = ContinuousClock.now - start
            census.invalidate()
            total += elapsed
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            XCTAssertNotNil(counts, "\(name): census が完走しません")
            let record: [String: Any] = [
                "book": name,
                "spineItems": publication.readingOrder.count,
                "counts": counts ?? [],
                "seconds": seconds,
            ]
            let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try handle.write(contentsOf: line + Data("\n".utf8))
            print("[Washi census bench] \(name): spine \(publication.readingOrder.count) 項目 / "
                  + String(format: "%.3f s", seconds))
        }
        print("[Washi census bench] 合計 \(books.count) 冊 / \(total)")
    }

    /// パス順に走査し、開けて spine が上限以下でリフロー項目を含む本を先頭から
    /// `maximumBooks` 冊選ぶ(選択は決定的)。名前はコーパス直下からの相対パス
    private static func reflowableBooks(in root: URL) -> [(URL, String)] {
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
                  publication.readingOrder.contains(where: {
                      publication.package.effectiveLayout(for: $0.itemRef) != .prePaginated
                  })
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
