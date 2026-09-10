import Foundation

/// ZIP エントリ検証用の CRC-32(IEEE 802.3 多項式 0xEDB88320)。
/// 外部依存を増やさず、8 本のテーブルで 8 バイトずつ処理する。
enum CRC32 {
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            tables[i] = c
        }
        // 先頭の表から、後続のゼロバイトを畳み込んだ表を導く。
        for slice in 1..<8 {
            for i in 0..<256 {
                let previous = tables[(slice - 1) * 256 + i]
                tables[slice * 256 + i] =
                    tables[Int(previous & 0xFF)] ^ (previous >> 8)
            }
        }
        return tables
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while bytes.count - offset >= 8 {
                // Data のスライスは整列を保証しないため非整列読み取りを使い、
                // ホストのバイト順に依存せず下位バイトから畳み込む。
                let first = UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: offset, as: UInt32.self)) ^ crc
                let second = UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: offset + 4, as: UInt32.self))
                crc = tables[7 * 256 + Int(first & 0xFF)]
                    ^ tables[6 * 256 + Int((first >> 8) & 0xFF)]
                    ^ tables[5 * 256 + Int((first >> 16) & 0xFF)]
                    ^ tables[4 * 256 + Int(first >> 24)]
                    ^ tables[3 * 256 + Int(second & 0xFF)]
                    ^ tables[2 * 256 + Int((second >> 8) & 0xFF)]
                    ^ tables[256 + Int((second >> 16) & 0xFF)]
                    ^ tables[Int(second >> 24)]
                offset += 8
            }
            // 末尾の 0〜7 バイトは従来の 1 バイト処理で畳み込む。
            while offset < bytes.count {
                crc = tables[Int((crc ^ UInt32(bytes[offset])) & 0xFF)] ^ (crc >> 8)
                offset += 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
