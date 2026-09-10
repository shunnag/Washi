import CryptoKit
import Foundation

/// META-INF/encryption.xml の解析結果(EPUB 3.3 OCF §4)。
///
/// Parsed result of META-INF/encryption.xml (EPUB 3.3 OCF §4).
///
/// 実際に流通する EPUB の「暗号化」は、次の 3 系統に分かれる。
///
/// The "encryption" that actually circulates in EPUBs falls into three families:
///
/// 1. IDPF/Adobe のフォント難読化(DRM ではなく、閲覧システム自身での解除が必須)
///    IDPF/Adobe font obfuscation (not DRM; the reading system is obligated to undo it itself)
/// 2. Adobe ADEPT や Readium LCP などの本来の DRM(鍵がないため開けない)
///    Genuine DRM such as Adobe ADEPT or Readium LCP (no key, so it cannot be opened)
/// 3. まれに独自方式
///    Rarely, a proprietary scheme
///
/// Washi は系統 1 を透過的に解除し、系統 2・3 では影響するリソースを特定して
/// エラーを報告する。
///
/// Washi transparently undoes family 1, and for families 2 and 3 it identifies the affected
/// resources and reports an error.
public struct EPUBEncryptionInfo: Sendable {
    /// 難読化アルゴリズム。
    ///
    /// Obfuscation algorithm.
    public enum ObfuscationAlgorithm: String, Sendable {
        /// IDPF 標準方式(20 バイトの SHA-1 鍵で先頭 1040 バイトを XOR する)。
        ///
        /// IDPF standard (20-byte SHA-1 key, XOR over the first 1040 bytes).
        case idpf = "http://www.idpf.org/2008/embedding"
        /// Adobe 方式(16 バイトの UUID 鍵で先頭 1024 バイトを XOR する)。
        ///
        /// Adobe scheme (16-byte UUID key, XOR over the first 1024 bytes).
        case adobe = "http://ns.adobe.com/pdf/enc#RC"
    }

    /// 正規化したコンテナ内パスから難読化アルゴリズムへの対応。
    ///
    /// Container-internal path (normalized) → obfuscation algorithm.
    public let obfuscatedResources: [String: ObfuscationAlgorithm]
    /// 未知のアルゴリズムで暗号化されたリソース(パス → Algorithm URI)。
    /// spine の本文が含まれる場合は、本が DRM で保護されていることを示す。
    ///
    /// Resources encrypted with an unknown algorithm (path → Algorithm URI).
    /// When spine content is among them, this is evidence that the book is DRM-protected.
    public let unknownEncryptedResources: [String: String]

    public var isEmpty: Bool {
        obfuscatedResources.isEmpty && unknownEncryptedResources.isEmpty
    }

    static let empty = EPUBEncryptionInfo(obfuscatedResources: [:],
                                          unknownEncryptedResources: [:])

    /// META-INF/encryption.xml を解析する
    static func parse(data: Data) throws -> EPUBEncryptionInfo {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("encryption.xml")
        }
        var obfuscated: [String: ObfuscationAlgorithm] = [:]
        var unknown: [String: String] = [:]
        for encryptedData in root.wsChildren("EncryptedData", ns: XMLNamespace.xmlEnc) {
            guard let algorithm = encryptedData
                .wsFirst("EncryptionMethod", ns: XMLNamespace.xmlEnc)?
                .attr("Algorithm") else { continue }
            guard let uri = encryptedData
                .wsFirst("CipherData", ns: XMLNamespace.xmlEnc)?
                .wsFirst("CipherReference", ns: XMLNamespace.xmlEnc)?
                .attr("URI") else { continue }
            // CipherReference URI はコンテナルート相対
            let path = ContainerPath.normalize(uri)
            if let known = ObfuscationAlgorithm(rawValue: algorithm) {
                obfuscated[path] = known
            } else {
                unknown[path] = algorithm
            }
        }
        return EPUBEncryptionInfo(obfuscatedResources: obfuscated,
                                  unknownEncryptedResources: unknown)
    }
}

/// フォントの難読化を解除する。
/// 難読化は、識別子から導いた鍵で先頭 n バイトを XOR するだけの可逆変換。
/// 鍵は本の unique-identifier から導出する(EPUB 3.3 OCF §4.4)。
///
/// Reversal of font mangling (font obfuscation).
/// Obfuscation is merely a reversible transform that XORs the first n bytes with an
/// identifier-derived key; the key is derived from the book's unique-identifier (EPUB 3.3 OCF §4.4).
public enum FontDeobfuscator {
    /// IDPF 方式の鍵。unique-identifier から空白(スペース、タブ、CR、LF)を
    /// すべて除いた UTF-8 バイト列の SHA-1(20 バイト)。
    ///
    /// IDPF-scheme key: the SHA-1 (20 bytes) of the UTF-8 byte sequence of the
    /// unique-identifier with all whitespace (space, tab, CR, LF) removed.
    public static func idpfKey(uniqueIdentifier: String) -> Data {
        let stripped = uniqueIdentifier.unicodeScalars
            .filter { !["\u{20}", "\u{9}", "\u{D}", "\u{A}"].contains(Character($0)) }
            .map(Character.init)
        let cleaned = String(stripped)
        let digest = Insecure.SHA1.hash(data: Data(cleaned.utf8))
        return Data(digest)
    }

    /// Adobe 方式の鍵。識別子から "urn:uuid:" 接頭辞・ハイフン・空白を除いた
    /// 32 桁の 16 進数を、16 バイトへ復号する。
    ///
    /// Adobe-scheme key: the identifier's 32 hex digits — with the "urn:uuid:" prefix,
    /// hyphens, and whitespace removed — decoded into 16 bytes.
    public static func adobeKey(uniqueIdentifier: String) -> Data? {
        var cleaned = uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["urn:uuid:", "urn:UUID:"] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        cleaned = cleaned.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard cleaned.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// バイト列がフォントのシグネチャ(sfnt / OpenType / WOFF)で始まるか。
    /// 難読化を正しく解除できたか、それとも鍵が間違っているか、
    /// `encryption.xml` の宣言が古いまま残っているかを見分けるために使う。
    /// 後二者では結果が壊れ、WebKit が黙って代替フォントへフォールバックする。
    ///
    /// Whether the bytes start with a font signature (sfnt / OpenType / WOFF).
    /// Used to tell a correct deobfuscation from a wrong key or a stale
    /// `encryption.xml` declaration: the result is garbage in both cases, and
    /// WebKit then silently falls back to a substitute font.
    public static func looksLikeFont(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = data.prefix(4)
        let signatures: [[UInt8]] = [
            [0x00, 0x01, 0x00, 0x00],           // TrueType
            Array("true".utf8),                 // TrueType (Apple)
            Array("ttcf".utf8),                 // TrueType Collection
            Array("OTTO".utf8),                 // CFF OpenType
            Array("wOFF".utf8),                 // WOFF
            Array("wOF2".utf8),                 // WOFF2
        ]
        return signatures.contains(Array(magic))
    }

    /// データの難読化を解除する(XOR は同じ操作を 2 回行うと元に戻るため、
    /// 適用する操作と解除する操作は同じ)。
    ///
    /// Undo obfuscated data (XOR is an involution, so applying it equals undoing it).
    public static func deobfuscate(
        _ data: Data, algorithm: EPUBEncryptionInfo.ObfuscationAlgorithm,
        uniqueIdentifier: String) -> Data {
        let key: Data?
        let prefixLength: Int
        switch algorithm {
        case .idpf:
            key = idpfKey(uniqueIdentifier: uniqueIdentifier)
            prefixLength = 1040
        case .adobe:
            key = adobeKey(uniqueIdentifier: uniqueIdentifier)
            prefixLength = 1024
        }
        guard let key, !key.isEmpty else { return data }
        var result = data
        let count = min(prefixLength, result.count)
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) in
                for i in 0..<count {
                    bytes[i] ^= keyBytes[i % key.count]
                }
            }
        }
        return result
    }
}
