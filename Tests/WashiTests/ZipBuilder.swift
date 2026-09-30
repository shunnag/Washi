import Compression
import Foundation
@testable import Washi
@testable import WashiCore

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
    mutating func appendLE32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }
    mutating func appendLE64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }
}

/// テスト用の最小 ZIP ライタ(store / deflate、zip64 強制モード付き)。
/// Washi 本体はリーダーしか持たないため、テスト側で正しい ZIP を手組みする
enum ZipBuilder {
    static func deflate(_ data: Data) -> Data {
        // 空の項目を deflate する場合も、最終ブロックと終端の印は必要になる。
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        var dst = Data(count: data.count + 4096)
        let capacity = dst.count
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
                compression_encode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return dst.prefix(written)
    }

    /// method: 0=store / 8=deflate
    static func build(_ entries: [(name: String, data: Data)],
                      method: UInt16 = 0, forceZip64: Bool = false) -> Data {
        var out = Data()
        var cd = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let payload = method == 8 ? deflate(data) : data
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            out.appendLE32(0x0403_4B50)
            out.appendLE16(20)              // version needed
            out.appendLE16(0x0800)          // flags: UTF-8
            out.appendLE16(method)
            out.appendLE16(0)               // time
            out.appendLE16(0)               // date
            out.appendLE32(crc)
            out.appendLE32(UInt32(payload.count))
            out.appendLE32(UInt32(data.count))
            out.appendLE16(UInt16(nameBytes.count))
            out.appendLE16(0)               // extra len
            out.append(nameBytes)
            out.append(payload)

            cd.appendLE32(0x0201_4B50)
            cd.appendLE16(20)               // version made by
            cd.appendLE16(20)               // version needed
            cd.appendLE16(0x0800)
            cd.appendLE16(method)
            cd.appendLE16(0)
            cd.appendLE16(0)
            cd.appendLE32(crc)
            if forceZip64 {
                cd.appendLE32(0xFFFF_FFFF)
                cd.appendLE32(0xFFFF_FFFF)
            } else {
                cd.appendLE32(UInt32(payload.count))
                cd.appendLE32(UInt32(data.count))
            }
            cd.appendLE16(UInt16(nameBytes.count))
            var extra = Data()
            if forceZip64 {
                extra.appendLE16(0x0001)
                extra.appendLE16(24)
                extra.appendLE64(UInt64(data.count))     // uncompressed
                extra.appendLE64(UInt64(payload.count))  // compressed
                extra.appendLE64(UInt64(offset))
            }
            cd.appendLE16(UInt16(extra.count))
            cd.appendLE16(0)                // comment len
            cd.appendLE16(0)                // disk start
            cd.appendLE16(0)                // internal attrs
            cd.appendLE32(0)                // external attrs
            cd.appendLE32(forceZip64 ? 0xFFFF_FFFF : offset)
            cd.append(nameBytes)
            cd.append(extra)
        }
        let cdOffset = out.count
        out.append(cd)
        if forceZip64 {
            let zip64Offset = out.count
            out.appendLE32(0x0606_4B50)
            out.appendLE64(44)              // record size (残り 44 バイト)
            out.appendLE16(45)
            out.appendLE16(45)
            out.appendLE32(0)
            out.appendLE32(0)
            out.appendLE64(UInt64(entries.count))
            out.appendLE64(UInt64(entries.count))
            out.appendLE64(UInt64(cd.count))
            out.appendLE64(UInt64(cdOffset))
            out.appendLE32(0x0706_4B50)
            out.appendLE32(0)
            out.appendLE64(UInt64(zip64Offset))
            out.appendLE32(1)
            out.appendLE32(0x0605_4B50)
            out.appendLE16(0)
            out.appendLE16(0)
            out.appendLE16(0xFFFF)
            out.appendLE16(0xFFFF)
            out.appendLE32(0xFFFF_FFFF)
            out.appendLE32(0xFFFF_FFFF)
            out.appendLE16(0)
        } else {
            out.appendLE32(0x0605_4B50)
            out.appendLE16(0)
            out.appendLE16(0)
            out.appendLE16(UInt16(entries.count))
            out.appendLE16(UInt16(entries.count))
            out.appendLE32(UInt32(cd.count))
            out.appendLE32(UInt32(cdOffset))
            out.appendLE16(0)
        }
        return out
    }
}
