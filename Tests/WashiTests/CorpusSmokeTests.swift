import Foundation
import XCTest
import WashiCore

final class CorpusSmokeTests: XCTestCase {
    private static let perBookBudget: TimeInterval = 20

    private static let japaneseSamplePrefixes = [
        "kusamakura-japanese-vertical-writing",
        "jlreq-in-japanese",
        "haruko-ahl",
        "haruko-html-jpeg",
        "haruko-jpeg",
        "vertically-scrollable-manga",
        "horizontally-scrollable-emakimono",
    ]

    // 2026-09 時点で ocf-zip-mult と
    // lay-pp-spine-overrides_image-spine-reflow の両方が完走することを実測で確認した。
    // 期待失敗が残っていないため、テーブルと特例処理を廃止し、全冊に通常の smoke pass を行う。
    // ocf-zip-mult は本来「分割 ZIP をエラーとする」負のテストだが、展開後の
    // 再 ZIP では通常の ZIP になるため、成功を受理する設計は維持する。
    // 両サンプルを含め、将来また失敗した場合はテストを赤くし、退行や上流の破損を検出する。
    func testPublicCorpusSmoke() throws {
        let root = try Self.corpusDirectory()
        let books = Self.books(in: root)
        guard !books.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR に EPUB がありません: \(root.path)")
        }

        var opened = 0
        var failures = 0

        for bookURL in books {
            let name = Self.bookName(bookURL)
            let startedAt = Date()

            do {
                let publication = try EPUBPublication(url: bookURL)
                _ = publication.metadata.mainTitle
                XCTAssertFalse(
                    publication.readingOrder.isEmpty,
                    "\(name): readingOrder が空です")
                _ = publication.navigation.flattenedTOC

                for item in publication.readingOrder.prefix(3) {
                    _ = try publication.extractText(
                        forSpineIndex: item.spineIndex)
                }
                _ = publication.search("the")
                _ = publication.coverImage(maxPixelSize: 64)
                _ = try publication.fixedLayoutInfo(forSpineIndex: 0)

                for path in publication.resourcePaths {
                    _ = try publication.resource(at: path)
                }
                opened += 1
            } catch {
                failures += 1
                XCTFail("\(name): WashiCore smoke pass が失敗しました: \(error)")
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            XCTAssertLessThanOrEqual(
                elapsed,
                Self.perBookBudget,
                "\(name): \(String(format: "%.3f", elapsed)) 秒かかりました (上限 20 秒)")
        }

        print(
            "[Washi corpus] 合計 \(books.count) 冊、成功 \(opened) 冊、" +
            "失敗 \(failures) 冊")
    }

    func testKnownJapaneseSamples() throws {
        let root = try Self.corpusDirectory()
        let books = Self.books(in: root)
        var checked = 0
        var missing = 0

        for prefix in Self.japaneseSamplePrefixes {
            guard let bookURL = books.first(where: {
                Self.bookName($0).hasPrefix(prefix)
            }) else {
                missing += 1
                print("[Washi corpus] 日本語サンプルなし (スキップ): \(prefix)")
                continue
            }

            do {
                let publication = try EPUBPublication(url: bookURL)

                if prefix == "kusamakura-japanese-vertical-writing"
                    || prefix.hasPrefix("haruko-") {
                    XCTAssertEqual(
                        publication.readingDirection, .rtl,
                        "\(prefix): readingDirection")
                }
                if prefix.hasPrefix("haruko-") {
                    XCTAssertTrue(publication.isFixedLayout, "\(prefix): FXL")
                }
                if prefix == "kusamakura-japanese-vertical-writing"
                    || prefix == "jlreq-in-japanese" {
                    XCTAssertFalse(
                        publication.navigation.flattenedTOC.isEmpty,
                        "\(prefix): TOC が空です")
                }
                if prefix == "kusamakura-japanese-vertical-writing" {
                    XCTAssertTrue(
                        publication.hasMediaOverlays,
                        "\(prefix): media overlay がありません")
                }
                checked += 1
            } catch {
                XCTFail("\(prefix): 日本語サンプルを開けません: \(error)")
            }
        }

        print("[Washi corpus] 日本語サンプル確認 \(checked) 冊、不在 \(missing) 冊")
    }

    private static func corpusDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["WASHI_CORPUS_DIR"],
              !path.isEmpty else {
            throw XCTSkip("WASHI_CORPUS_DIR が未設定です")
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("WASHI_CORPUS_DIR が存在しません: \(url.path)")
        }
        return url
    }

    private static func books(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        let propertyKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let directEntries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: propertyKeys,
            options: [.skipsHiddenFiles])) ?? []
        var candidates = directEntries

        // corpus/samples/*.epub など、ルート直下のディレクトリを 1 段だけ見る。
        for entry in directEntries where Self.isDirectory(entry) {
            let children = (try? fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: propertyKeys,
                options: [.skipsHiddenFiles])) ?? []
            candidates.append(contentsOf: children)
        }

        var unique: [String: URL] = [:]
        for candidate in candidates where Self.isBook(candidate) {
            let standardized = candidate.standardizedFileURL
            unique[standardized.path] = standardized
        }
        return unique.values.sorted { $0.path < $1.path }
    }

    private static func isBook(_ url: URL) -> Bool {
        if isDirectory(url) {
            var mimetypeIsDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.appendingPathComponent("mimetype").path,
                isDirectory: &mimetypeIsDirectory)
                && !mimetypeIsDirectory.boolValue
        }
        return url.pathExtension.lowercased() == "epub"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func bookName(_ url: URL) -> String {
        url.pathExtension.lowercased() == "epub"
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
    }
}
