import Foundation
import XCTest
@testable import WashiCore

/// 宣言された大きさと CRC は deflate ストリーム全体を表していなければならず、
/// 呼び出し側の出力バッファにたまたま収まった先頭部分だけでは足りない。
final class ZipIntegrityTests: XCTestCase {
    private func archive(stream: Data, declared: Data) throws -> ZipArchive {
        let name = "payload.bin"
        var zip = ZipBuilder.build([(name, stream)])
        let central = 30 + name.utf8.count + stream.count
        for offset in [8, central + 10] {
            zip[offset] = 8 // Keep the raw payload but declare deflate.
        }
        for offset in [14, central + 16] {
            for i in 0..<4 {
                zip[offset + i] = UInt8(truncatingIfNeeded: CRC32.checksum(declared) >> (8 * i))
            }
        }
        for offset in [22, central + 24] {
            for i in 0..<4 {
                zip[offset + i] = UInt8(truncatingIfNeeded: declared.count >> (8 * i))
            }
        }
        return try ZipArchive(data: zip)
    }

    private func storedDeflate(_ data: Data, final: Bool = true) -> Data {
        precondition(data.count <= Int(UInt16.max))
        var stream = Data([final ? 1 : 0])
        stream.appendLE16(UInt16(data.count))
        stream.appendLE16(~UInt16(data.count))
        stream.append(data)
        return stream
    }

    func testRejectsUndeclaredOutputEvenWhenPrefixCRCMatches() throws {
        let payload = Data("read the entire stream".utf8)
        let zip = try archive(stream: storedDeflate(payload), declared: Data(payload.prefix(4)))
        XCTAssertThrowsError(try zip.data(forEntry: "payload.bin"))
    }

    func testRejectsMissingEndOfStreamEvenWhenSizeAndCRCMatch() throws {
        let payload = Data("complete text, incomplete stream".utf8)
        let zip = try archive(stream: storedDeflate(payload, final: false), declared: payload)
        XCTAssertThrowsError(try zip.data(forEntry: "payload.bin"))
    }

    func testRejectsPayloadDisguisedAsEmptyEntry() throws {
        let zip = try archive(stream: storedDeflate(Data("hidden".utf8)), declared: Data())
        XCTAssertThrowsError(try zip.data(forEntry: "payload.bin"))
    }

    func testRejectsInvalidDeflateForEmptyEntry() throws {
        let zip = try archive(stream: Data([0xff, 0xff]), declared: Data())
        XCTAssertThrowsError(try zip.data(forEntry: "payload.bin"))
    }

    func testAcceptsValidEmptyDeflate() throws {
        for stream in [Data([0x03, 0x00]), storedDeflate(Data())] {
            let zip = try archive(stream: stream, declared: Data())
            XCTAssertEqual(try zip.data(forEntry: "payload.bin"), Data())
        }
    }

    func testAcceptsTrailingBytesAfterCompleteDeflateStream() throws {
        let payload = Data("text".utf8)
        let zip = try archive(stream: storedDeflate(payload) + Data([0xff]), declared: payload)
        // zlib 系のリーダーと同じく、完結したストリームの後ろの詰め物は受け入れる。
        // 圧縮側は先読みすることがあり、src_size ではストリームの正確な終端を特定できない。
        XCTAssertEqual(try zip.data(forEntry: "payload.bin"), payload)
    }

    func testRejectsAbsentStreamEvenForEmptyEntry() throws {
        let zip = try archive(stream: Data(), declared: Data())
        XCTAssertThrowsError(try zip.data(forEntry: "payload.bin"))
    }

    func testRejectsOutputShorterThanDeclaredSize() throws {
        let zip = try archive(stream: storedDeflate(Data("text".utf8)),
                              declared: Data("text with missing suffix".utf8))
        XCTAssertThrowsError(try zip.data(forEntry: "payload.bin"))
    }

    func testLargeDeflateRoundTripAcrossOutputChunks() throws {
        let payload = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let zip = try ZipArchive(data: ZipBuilder.build([("payload.bin", payload)], method: 8))
        XCTAssertEqual(try zip.data(forEntry: "payload.bin"), payload)
    }

    func testDeflateRoundTripBeyondPreallocationLimit() throws {
        // 4 MiB の事前確保上限を超えても、出力全体が元の内容と一致することを確認する。
        let payload = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let zip = try ZipArchive(data: ZipBuilder.build([("payload.bin", payload)], method: 8))
        XCTAssertEqual(try zip.data(forEntry: "payload.bin"), payload)
    }
}
