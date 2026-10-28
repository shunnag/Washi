import Foundation
import zlib

/// ZIP エントリ検証用の CRC-32(IEEE 802.3 多項式 0xEDB88320)。
/// OS 標準の zlib を使い、外部パッケージへの依存を増やさない。
enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var crc = zlib.crc32(0, nil, 0)
            if let source = bytes.bindMemory(to: UInt8.self).baseAddress {
                var offset = 0
                while offset < bytes.count {
                    // zlib の長さ引数は uInt なので、大きな入力は分割して累積する。
                    let count = min(bytes.count - offset, Int(UInt32.max))
                    crc = zlib.crc32(crc, source.advanced(by: offset), uInt(count))
                    offset += count
                }
            }
            return UInt32(crc)
        }
    }
}
