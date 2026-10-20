import Darwin
import Foundation
import XCTest
@testable import WashiCore

final class ContainerIORecoveryTests: XCTestCase {
    func testHundredsOfMappedZIPsDoNotRetainFileDescriptors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try ZipBuilder.build(EPUBFixtures.verticalNovelEntries())
        func descriptorCount() -> Int { (0..<1024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
        let before = descriptorCount()
        var retained: [ZipArchive] = []
        for index in 0..<300 {
            let url = root.appendingPathComponent("book-\(index).epub")
            try bytes.write(to: url)
            retained.append(try ZipArchive(url: url))
        }
        XCTAssertLessThanOrEqual(descriptorCount() - before, 2)
        for index in [0, 150, 299] {
            XCTAssertEqual(try retained[index].data(forEntry: "mimetype"), Data("application/epub+zip".utf8))
        }
        withExtendedLifetime(retained) {}
    }

    func testOptionalMetadataIOFailuresArePropagatedAndRecoverOnReopen() throws {
        let paths = ["mimetype", "META-INF/encryption.xml", "OEBPS/nav.xhtml", "OEBPS/toc.ncx",
                     "META-INF/com.apple.ibooks.display-options.xml", "META-INF/com.kobobooks.display-options.xml"]
        for path in paths {
            var entries = Dictionary(uniqueKeysWithValues: EPUBFixtures.verticalNovelEntries().map { ($0.name, $0.data) })
            if entries[path] == nil { entries[path] = Data("<metadata/>".utf8) }
            if path == "OEBPS/toc.ncx" { entries["OEBPS/nav.xhtml"] = Data("<html/>".utf8) }
            let url = URL(fileURLWithPath: "/tmp/synthetic.epub")
            for code in [EMFILE, EACCES] {
                XCTAssertThrowsError(try EPUBPublication(url: url,
                    reader: FaultingContainerReader(entries: entries, failingPath: path, code: code))) {
                    let error = $0 as NSError
                    XCTAssertEqual(error.domain, NSPOSIXErrorDomain, path)
                    XCTAssertEqual(error.code, Int(code), path)
                }
            }
            let recovered = try EPUBPublication(url: url, reader: FaultingContainerReader(entries: entries))
            XCTAssertEqual(recovered.readingOrder.count, 3)
        }
    }

    func testRealDescriptorExhaustionIsNotReportedAsMissingResourceOrInvalidEPUB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("book.epub")
        try ZipBuilder.build(EPUBFixtures.verticalNovelEntries()).write(to: file)
        let reader = FolderContainerReader(rootURL: root, readStrategy: .alwaysCopy)
        var saved = rlimit(); XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        var limited = saved; limited.rlim_cur = min(saved.rlim_cur, 256)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limited), 0)
        defer { _ = setrlimit(RLIMIT_NOFILE, &saved) }
        var descriptors: [Int32] = []
        while true {
            let fd = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            if fd < 0 { break }
            descriptors.append(fd)
        }
        var readError: Error?, openError: Error?
        do { _ = try reader.read("book.epub") } catch { readError = error }
        do { _ = try EPUBPublication(url: file, readStrategy: .alwaysCopy) } catch { openError = error }
        for fd in descriptors { Darwin.close(fd) }
        XCTAssertNotNil(readError)
        XCTAssertNotNil(openError)
        XCTAssertFalse(readError is EPUBError)
        XCTAssertFalse(openError is EPUBError)
        XCTAssertFalse(try reader.read("book.epub").isEmpty)
        XCTAssertEqual(try EPUBPublication(url: file).readingOrder.count, 3)
    }

    func testMissingAndCorruptOptionalMetadataKeepExistingTolerance() throws {
        let reader = FaultingContainerReader(entries: [:])
        XCTAssertNil(try optionalContainerData(reader, at: "missing"))
        let corrupt = FaultingContainerReader(entries: ["bad": Data()], failingPath: "bad", code: nil)
        XCTAssertNil(try optionalContainerData(corrupt, at: "bad"))
    }
}

private struct FaultingContainerReader: ContainerReader {
    let entries: [String: Data]
    var failingPath: String?
    var code: Int32? = EMFILE
    var allPaths: [String] { Array(entries.keys) }
    func exists(_ path: String) -> Bool { entries[path] != nil }
    func read(_ path: String) throws -> Data {
        if path == failingPath {
            if let code { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            throw EPUBError.containerReadFailed(path: path, reason: "synthetic corrupt metadata")
        }
        guard let bytes = entries[path] else { throw EPUBError.resourceNotFound(path) }
        return bytes
    }
}
