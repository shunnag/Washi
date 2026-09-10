import Foundation

/// cooViewer-oxr.46 C42: WebKit に別名の無い `-epub-` 接頭辞 CSS を、配信時に
/// 標準プロパティで補う。
///
/// WebKit は `-epub-writing-mode` などの多くを標準プロパティの別名として解釈
/// するが、次の 6 つは解釈しない(macOS 26 / WebKit で実測)。とくに
/// `-epub-text-combine-horizontal: all` は日本語縦書きの縦中横そのもので、
/// 電書協テンプレート系の本で広く使われている。
///
/// 元の宣言は残したまま標準プロパティの宣言を後ろへ足すだけなので、WebKit が
/// 将来 `-epub-` を解釈するようになっても結果は変わらない(同じ値になる)。
public enum EPUBPrefixedCSS {
    /// 補う対象(`-epub-` 名 → 標準名)。WebKit が解釈するものは入れない。
    static let unsupported: [(prefixed: String, standard: String)] = [
        ("-epub-text-combine-horizontal", "text-combine-upright"),
        ("-epub-line-break", "line-break"),
        ("-epub-text-align-last", "text-align-last"),
        ("-epub-text-emphasis-position", "text-emphasis-position"),
        ("-epub-text-underline-position", "text-underline-position"),
        ("-epub-ruby-position", "ruby-position"),
    ]

    /// スタイルシート本文に標準プロパティの宣言を補う。
    /// コメント・文字列・関数・カスタムプロパティの中身はそのまま保つ。
    public static func polyfilled(_ css: String) -> String {
        let input = Array(css.utf8)
        let properties = Dictionary(uniqueKeysWithValues: unsupported.map { ($0.prefixed, $0.standard) })
        var output: [UInt8] = []
        var unchangedStart = 0
        var index = 0
        var startsStatement = true
        var groups: [UInt8] = []

        while index < input.count {
            let next = skippingTrivia(input, from: index)
            if next != index { index = next; continue }
            let byte = input[index]
            if byte == 0x22 || byte == 0x27 {
                index = skippingString(input, from: index)
                startsStatement = false
                continue
            }
            if byte == 0x5c { // An escaped delimiter is not CSS structure.
                index += min(2, input.count - index)
                startsStatement = false
                continue
            }
            if groups.isEmpty, startsStatement {
                var nameEnd = index
                while nameEnd < input.count, isNameByte(input[nameEnd]) { nameEnd += 1 }
                let name = String(decoding: input[index..<nameEnd], as: UTF8.self).lowercased()
                let colon = skippingTrivia(input, from: nameEnd)
                if colon < input.count, input[colon] == 0x3a,
                   properties[name] != nil || name.hasPrefix("--") {
                    let custom = name.hasPrefix("--")
                    let end = endOfValue(input, from: colon + 1, custom: custom)
                    // A top-level brace starts a nested rule, not a value for
                    // one of these six properties. Leave such selectors alone.
                    if custom || end == input.count || input[end] != 0x7b {
                        if let standard = properties[name] {
                            let value = String(decoding: input[(colon + 1)..<end], as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !value.isEmpty {
                                output.append(contentsOf: input[unchangedStart..<end])
                                output.append(contentsOf: "; \(standard): \(value)".utf8)
                                unchangedStart = end
                            }
                        }
                        index = end
                        startsStatement = false
                        continue
                    }
                }
            }
            switch byte {
            case 0x28: groups.append(0x29) // (
            case 0x5b: groups.append(0x5d) // [
            case 0x29, 0x5d:
                if groups.last == byte { groups.removeLast() }
            default: break
            }
            startsStatement = groups.isEmpty && (byte == 0x7b || byte == 0x7d || byte == 0x3b)
            index += 1
        }
        guard unchangedStart != 0 else { return css }
        output.append(contentsOf: input[unchangedStart...])
        return String(decoding: output, as: UTF8.self)
    }

    /// テキスト種別が CSS のときだけ通す入口。
    public static func polyfilledStylesheet(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "-epub-", options: .caseInsensitive) != nil else { return data }
        let converted = polyfilled(text)
        return converted == text ? data : Data(converted.utf8)
    }

    private static func skippingTrivia(_ input: [UInt8], from start: Int) -> Int {
        var index = start
        while index < input.count {
            if [0x09, 0x0a, 0x0c, 0x0d, 0x20].contains(input[index]) {
                index += 1
            } else if index + 1 < input.count, input[index] == 0x2f, input[index + 1] == 0x2a {
                index += 2
                while index + 1 < input.count,
                      !(input[index] == 0x2a && input[index + 1] == 0x2f) { index += 1 }
                index = min(input.count, index + 2)
            } else { break }
        }
        return index
    }

    private static func skippingString(_ input: [UInt8], from start: Int) -> Int {
        let quote = input[start]
        var index = start + 1
        while index < input.count {
            let byte = input[index]
            index += 1
            if byte == quote { break }
            if byte == 0x5c, index < input.count { index += 1 }
        }
        return index
    }

    private static func endOfValue(_ input: [UInt8], from start: Int, custom: Bool) -> Int {
        var index = start
        var groups: [UInt8] = []
        while index < input.count {
            let next = skippingTrivia(input, from: index)
            if next != index { index = next; continue }
            let byte = input[index]
            if byte == 0x22 || byte == 0x27 {
                index = skippingString(input, from: index)
                continue
            }
            if byte == 0x5c {
                index += min(2, input.count - index)
                continue
            }
            if groups.isEmpty && (byte == 0x3b || byte == 0x7d || (!custom && byte == 0x7b)) {
                return index
            }
            switch byte {
            case 0x28: groups.append(0x29)
            case 0x5b: groups.append(0x5d)
            case 0x7b: groups.append(0x7d)
            case 0x29, 0x5d, 0x7d:
                if groups.last == byte { groups.removeLast() }
            default: break
            }
            index += 1
        }
        return index
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
            || (0x30...0x39).contains(byte) || byte == 0x2d || byte == 0x5f || byte >= 0x80
    }
}
