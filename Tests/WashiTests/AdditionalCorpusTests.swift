import Foundation
import XCTest
@testable import Washi
@testable import WashiCore

final class AdditionalCorpusTests: XCTestCase {
    private struct Book: Decodable {
        let path: String
        let language: String
        let query: String
        let source: String
        let license: String
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func books() throws -> [(book: Book, url: URL)] {
        let root = repositoryRoot()
        let directory = ProcessInfo.processInfo.environment["WASHI_EXTRA_CORPUS_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent(".build/epub-corpus-extra")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("追加コーパスがありません: \(directory.path)")
        }
        let manifestURL = root.appendingPathComponent("Tests/Corpus/Additional/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([Book].self, from: data).map {
            ($0, directory.appendingPathComponent($0.path))
        }
    }

    func testAdditionalMultilingualCorpus() throws {
        for (book, url) in try books() {
            let publication = try EPUBPublication(url: url, readStrategy: .alwaysCopy)
            XCTAssertFalse(publication.readingOrder.isEmpty, book.path)
            let text = publication.readingOrder.prefix(3).compactMap {
                try? publication.extractText(forSpineIndex: $0.spineIndex)
            }.joined(separator: "\n")
            XCTAssertFalse(text.isEmpty, book.path)
            XCTAssertFalse(publication.search(book.query).isEmpty, book.path)
            _ = publication.coverImage(maxPixelSize: 64)
            for path in publication.resourcePaths {
                _ = try publication.resource(at: path)
            }
        }
    }

    @MainActor
    func testAdditionalMultilingualRendering() async throws {
        for (book, url) in try books() {
            let publication = try EPUBPublication(url: url, readStrategy: .alwaysCopy)
            let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = ReaderViewDelegateSpy()
            view.delegate = delegate
            let window = makeOffscreenWindow(containing: view)
            view.load(publication: publication)
            let shown = await waitUntil(timeout: .seconds(10), poll: .milliseconds(20)) {
                delegate.moveCount > 0 && view.webView?.alphaValue == 1
            }
            XCTAssertTrue(shown, book.path)
            closeReader(view, in: window, teardown: .unload, clearsDelegate: true)
        }
    }
}
