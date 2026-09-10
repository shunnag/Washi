import XCTest
@testable import Washi
@testable import WashiCore

/// 自前 ZIP リーダーの検証(フィクスチャはテスト側の手組みライタで生成)
final class ZipArchiveTests: XCTestCase {
    private let sample: [(name: String, data: Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("<container/>".utf8)),
        ("OEBPS/日本語 ファイル.xhtml", Data(String(repeating: "縦組みのテキスト。", count: 200).utf8)),
        ("OEBPS/empty.txt", Data()),
    ]

    /// 空データと 1〜8 バイトの境界、および標準ベクタを固定値で検証する。
    func testCRC32KnownVectors() {
        let input = Data("123456789".utf8)
        let expected: [UInt32] = [
            0x0000_0000, 0x83DC_EFB7, 0x4F53_44CD, 0x8848_63D2,
            0x9BE3_E0A3, 0xCBF5_3A1C, 0x0972_D361, 0x5003_699F,
            0x9AE0_DAAF, 0xCBF4_3926,
        ]
        for (length, checksum) in expected.enumerated() {
            XCTAssertEqual(CRC32.checksum(input.prefix(length)), checksum,
                           "入力長: \(length)")
        }
        XCTAssertEqual(CRC32.checksum(Data((0..<256).map { UInt8($0) })),
                       0x2905_8C73)
    }

    /// テーブルを使わない独立した計算と照合し、各端数と非整列スライスを通す。
    func testCRC32MatchesBitwiseReferenceAcrossSliceBoundaries() {
        let input = Data((0..<4_112).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) })
        let lengths = Array(0...64) + [
            127, 128, 129, 255, 256, 257, 511, 512, 513,
            1_023, 1_024, 1_025, 4_095, 4_096, 4_097,
        ]
        for offset in 0..<8 {
            for length in lengths {
                let slice = input[offset..<(offset + length)]
                XCTAssertEqual(CRC32.checksum(slice), bitwiseCRC32(slice),
                               "開始位置: \(offset)、入力長: \(length)")
            }
        }
    }

    private func bitwiseCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// 内容が同じでも重複名は拒否し、リーダーごとの採用順に依存させない。
    func testDuplicateEntryNamesAreRejectedAtInitialization() {
        let name = "OEBPS/content.opf"
        for method: UInt16 in [0, 8] {
            for zip64 in [false, true] {
                for second in ["FIRST", "SECOND"] {
                    let zip = ZipBuilder.build([
                        (name, Data("FIRST".utf8)),
                        ("OEBPS/chapter.xhtml", Data("chapter".utf8)),
                        (name, Data(second.utf8)),
                    ], method: method, forceZip64: zip64)
                    XCTAssertThrowsError(try ZipArchive(data: zip)) { error in
                        XCTAssertEqual(error as? ZipError,
                                       .truncated("duplicate entry: \(name)"))
                    }
                }
            }
        }
    }

    func testEntryNamesRemainCaseSensitive() throws {
        let entries = [("A.xhtml", Data("upper".utf8)),
                       ("a.xhtml", Data("lower".utf8))]
        let archive = try ZipArchive(data: ZipBuilder.build(entries))
        XCTAssertEqual(archive.entries.map(\.name), entries.map { $0.0 })
        for (name, data) in entries {
            XCTAssertTrue(archive.contains(name))
            XCTAssertEqual(archive.info(for: name)?.name, name)
            XCTAssertEqual(try archive.data(forEntry: name), data)
        }
    }

    func testStoredRoundTrip() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample, method: 0))
        XCTAssertEqual(archive.entries.count, 4)
        for (name, data) in sample {
            XCTAssertTrue(archive.contains(name), name)
            XCTAssertEqual(try archive.data(forEntry: name), data, name)
        }
    }

    func testDeflateRoundTrip() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample, method: 8))
        for (name, data) in sample {
            XCTAssertEqual(try archive.data(forEntry: name), data, name)
        }
        // 圧縮が実際に効いていること(店晒し検出: deflate 経路を通った証拠)
        let info = try XCTUnwrap(archive.info(for: "OEBPS/日本語 ファイル.xhtml"))
        XCTAssertEqual(info.method, 8)
        XCTAssertLessThan(info.compressedSize, info.uncompressedSize)
    }

    func testZip64Structures() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample, forceZip64: true))
        XCTAssertEqual(archive.entries.count, 4)
        for (name, data) in sample {
            XCTAssertEqual(try archive.data(forEntry: name), data, name)
        }
    }

    func testCRCMismatchDetected() throws {
        var zip = ZipBuilder.build([("a.bin", Data([1, 2, 3, 4, 5, 6, 7, 8]))])
        // ローカルヘッダ(30 バイト)+ 名前(5)の直後 = データ先頭を破壊
        zip[35] ^= 0xFF
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "a.bin")) { error in
            guard case ZipError.corruptEntry = error else {
                return XCTFail("corruptEntry であるべき: \(error)")
            }
        }
    }

    /// cooViewer-oxr.17: ContainerReader 境界では欠落だけ resourceNotFound、
    /// それ以外の ZIP 読み取り失敗は英語理由付き containerReadFailed に写す。
    func testZipContainerMapsEveryReadFailureToEPUBError() throws {
        let path = "a.bin"
        let payload = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let original = ZipBuilder.build([(path, payload)])
        let dataOffset = 30 + path.utf8.count
        let centralDirectoryOffset = dataOffset + payload.count

        func assertMapped(_ archive: ZipArchive, reasonContains expected: String,
                          file: StaticString = #filePath, line: UInt = #line) {
            let reader = ZipContainerReader(archive: archive)
            XCTAssertThrowsError(try reader.read(path), file: file, line: line) { error in
                guard case EPUBError.containerReadFailed(
                    path: let failedPath, reason: let reason) = error
                else {
                    return XCTFail("containerReadFailed ではない: \(error)",
                                   file: file, line: line)
                }
                XCTAssertEqual(failedPath, path, file: file, line: line)
                XCTAssertTrue(reason.contains(expected), reason,
                              file: file, line: line)
            }
        }

        var corrupt = original
        corrupt[dataOffset] ^= 0xFF
        assertMapped(try ZipArchive(data: corrupt), reasonContains: "Corrupt entry")

        var encrypted = original
        encrypted[centralDirectoryOffset + 8] |= 0x01
        assertMapped(try ZipArchive(data: encrypted), reasonContains: "encrypted entry")

        var unsupported = original
        unsupported[centralDirectoryOffset + 10] = 99
        unsupported[centralDirectoryOffset + 11] = 0
        assertMapped(try ZipArchive(data: unsupported),
                     reasonContains: "Unsupported compression method")

        var truncated = original
        truncated[0] = 0
        assertMapped(try ZipArchive(data: truncated), reasonContains: "Truncated")

        assertMapped(try ZipArchive(data: original, maxEntrySize: payload.count - 1),
                     reasonContains: "size limit")

        let reader = ZipContainerReader(archive: try ZipArchive(data: original))
        XCTAssertThrowsError(try reader.read("missing.bin")) { error in
            XCTAssertEqual(error as? EPUBError, .resourceNotFound("missing.bin"))
        }
    }

    func testEncryptedEntryRejected() throws {
        var zip = ZipBuilder.build([("secret.txt", Data("x".utf8))])
        // 中央ディレクトリのフラグに暗号化ビットを立てる(EOCD から辿る)
        // 手組みフィクスチャの構造上、CD はローカル(30+10+1)の直後
        let cdOffset = 30 + "secret.txt".utf8.count + 1
        XCTAssertEqual(zip[cdOffset], 0x50)  // CD シグネチャ確認
        zip[cdOffset + 8] |= 0x01
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "secret.txt")) { error in
            guard case ZipError.encryptedEntryUnsupported = error else {
                return XCTFail("encryptedEntryUnsupported であるべき: \(error)")
            }
        }
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipArchive(data: Data("これは ZIP ではない".utf8)))
        XCTAssertThrowsError(try ZipArchive(data: Data()))
    }

    func testUnknownEntry() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample))
        XCTAssertThrowsError(try archive.data(forEntry: "nonexistent")) { error in
            guard case ZipError.entryNotFound = error else {
                return XCTFail("entryNotFound であるべき: \(error)")
            }
        }
    }

    /// ZIP コメント内に偽 EOCD シグネチャがあっても正しい EOCD を選ぶ
    func testEOCDWithTrailingComment() throws {
        var zip = ZipBuilder.build(sample)
        // コメント付き EOCD に書き換える: 末尾 2 バイト(comment len)を書き換えて
        // 偽シグネチャ入りコメントを付与
        let comment = Data([0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00])
        zip[zip.count - 2] = UInt8(comment.count & 0xFF)
        zip[zip.count - 1] = UInt8(comment.count >> 8)
        zip.append(comment)
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(archive.entries.count, 4)
        XCTAssertEqual(try archive.data(forEntry: "mimetype"),
                       Data("application/epub+zip".utf8))
    }
}
