import Foundation

/// EPUB 関連 XML の名前空間 URI
enum XMLNamespace {
    static let container = "urn:oasis:names:tc:opendocument:xmlns:container"
    static let opf = "http://www.idpf.org/2007/opf"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let xhtml = "http://www.w3.org/1999/xhtml"
    static let epubOps = "http://www.idpf.org/2007/ops"
    static let ncx = "http://www.daisy.org/z3986/2005/ncx/"
    static let xmlEnc = "http://www.w3.org/2001/04/xmlenc#"
    static let smil = "http://www.w3.org/ns/SMIL"
    static let svg = "http://www.w3.org/2000/svg"
    static let mathML = "http://www.w3.org/1998/Math/MathML"
    static let xlink = "http://www.w3.org/1999/xlink"
}

/// XMLDocument ベースのパースヘルパ。
/// EPUB の XML は well-formed が仕様要件だが、実在ファイルには DTD 未定義の
/// HTML 名前実体(&nbsp; 等)が混ざることがある。既知実体を含むデータは解析の
/// 前に数値参照へ置換し、それでも失敗したら元データを置換し直して再試行する
/// (WebKit 側の描画には影響しない、Washi 自身がナビゲーション文書等を読む
/// ときだけの救済)。あわせて、深い木や大量のノードなど攻撃的な XML は
/// DOM を作る前に拒否する。
enum WashiXML {
    /// 可視本文か異なる img 参照があれば、DOM を作らず画像だけの文書を除外する。
    /// 肯定には文書全体の検証と SVG 名前空間の解決が必要なので従来の解析へ戻す。
    static func rejectsSingleImageDocument(_ data: Data) throws -> Bool {
        // 符号化を判別できないデータは解析せず DOM 経路へ戻す。
        // 走査で XMLParser を使う場合は必ず生データの prolog 検査を先に行う。
        let head = data.prefix(4)
        guard !head.contains(0), !head.starts(with: [0xFE, 0xFF]),
              !head.starts(with: [0xFF, 0xFE]) else { return false }
        try validateProlog(data)
        guard try !containsNamedEntity(data) else { return false }
        let scanner = SingleImageRejectionScanner()
        let parser = XMLParser(data: data)
        parser.delegate = scanner
        _ = parser.parse()
        return scanner.rejected
    }

    private final class SingleImageRejectionScanner: NSObject, XMLParserDelegate {
        private var stack: [(hidden: Bool, svg: Bool)] = []
        private var bodyDepth: Int?
        private var finishedBody = false
        private var firstSource: String?
        private(set) var rejected = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "body", bodyDepth == nil, !finishedBody { bodyDepth = stack.count }
            let svg = stack.last?.svg == true || name.lowercased() == "svg"
            let hidden = stack.last?.hidden == true || attributeDict["hidden"] != nil
                || ["script", "style"].contains(name.lowercased())
                || (svg && ["title", "desc"].contains(name.lowercased()))
                || attributeDict["style"]?.range(
                    of: #"(?:^|;)\s*display\s*:\s*none\s*(?:!important\s*)?(?:;|$)"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            stack.append((hidden, svg))
            // 深い木は従来の構造検証に任せ、走査の状態を無制限に増やさない。
            if stack.count > maxElementDepth { parser.abortParsing(); return }
            guard let bodyDepth, stack.count > bodyDepth + 1, name == "img" else { return }
            guard let source = attributeDict["src"],
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  firstSource == nil || firstSource == source else {
                reject(parser)
                return
            }
            firstSource = source
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard bodyDepth != nil, stack.last?.hidden == false,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            reject(parser)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
            if stack.count == bodyDepth { bodyDepth = nil; finishedBody = true }
        }

        private func reject(_ parser: XMLParser) {
            rejected = true
            parser.abortParsing()
        }
    }

    /// 外部実体は決して読み込まない(EPUB RS 3.3 §3.6 の要件 + XXE 対策)
    private static let options: XMLNode.Options = [
        .nodePreserveWhitespace, .nodeLoadExternalEntitiesNever,
    ]

    static func document(from data: Data) throws -> XMLDocument {
        try validateProlog(data)   // ← 生データ先行の現順序は維持(変更禁止)
        // 外部 DTD 参照付き DOCTYPE の XHTML では .nodeLoadExternalEntitiesNever の
        // 下で名前付き実体(&nbsp; 等)が空展開され、素パースが成功して catch の
        // 救済に入らない。既知実体を含むなら先に数値参照へ畳んでから解析し、
        // WebKit の DOM 本文と抽出テキストを一致させる(cooViewer-aj4)。
        // ※ CDATA/コメント内の見かけ実体も置換されるが、従来の catch 経路と同じ
        //   既知の制限(実在 EPUB では稀)。
        let source = try containsNamedEntity(data) ? sanitizeEntities(data) : data
        try validateStructure(source)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: source, options: options)
        } catch {
            // 前処理で拾えない実体・別の整形不良は従来どおり sanitize で再挑戦
            let sanitized = try sanitizeEntities(data)
            try validateStructure(sanitized)
            document = try XMLDocument(data: sanitized, options: options)
        }
        try validateDepth(document)
        return document
    }

    // MARK: - 攻撃的 XML の遮断

    /// 要素ネストの上限。実在 EPUB の XML(OPF/nav/NCX/SMIL 等)は深くても
    /// 数十段。これを大きく超える木は、下流の再帰ウォーカー
    /// (nav の入れ子リスト・NCX navPoint・SMIL seq 等)をスタック
    /// オーバーフロー(SIGSEGV)させる攻撃とみなして拒否する
    private static let maxElementDepth = 512

    /// 小さな XML から大量の DOM ノードが作られることによるメモリ枯渇を防ぐ
    private static let maxElementCount = 1_000_000

    private static func validateStructure(_ data: Data) throws {
        // Foundation の木の構築・解体は再帰的で、深い木は throw による
        // 巻き戻し中にもスタックを使い切る。DOM を作る前に SAX で制限する。
        let parser = XMLParser(data: data)
        let validator = StructureValidator()
        parser.delegate = validator
        // 外部実体は解決しない(shouldResolveExternalEntities は既定の false)。
        // 整形不良による失敗は判定せず、従来の DOM 解析・実体救済に任せる。
        _ = parser.parse()
        if let error = validator.error { throw error }
    }

    private final class StructureValidator: NSObject, XMLParserDelegate {
        private var depth = 0
        private var elementCount = 0
        private(set) var error: EPUBError?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard error == nil else { return }
            depth += 1
            elementCount += 1
            if depth > maxElementDepth {
                error = .malformed("XML のネストが深すぎる(\(maxElementDepth) 超)")
            } else if elementCount > maxElementCount {
                error = .malformed("XML の要素数が多すぎる(\(maxElementCount) 超)")
            }
            if error != nil { parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
        }
    }

    private static func validateDepth(_ document: XMLDocument) throws {
        guard let root = document.rootElement() else { return }
        var stack: [(node: XMLNode, depth: Int)] = [(root, 1)]
        while let (node, depth) = stack.popLast() {
            guard depth <= maxElementDepth else {
                throw EPUBError.malformed("XML のネストが深すぎる(\(maxElementDepth) 超)")
            }
            for child in node.children ?? [] {
                stack.append((child, depth + 1))
            }
        }
    }

    /// 内部 DTD の実体宣言を検査する。.nodeLoadExternalEntitiesNever は
    /// **外部**実体しか遮断せず、内部サブセットの実体展開(billion laughs)は
    /// 素通しでメモリ枯渇に至る。一方、実在の EPUB 2 系ファイルには
    /// `<!ENTITY nbsp "&#160;">` 程度の互換シムが紛れるため、全面禁止は
    /// せず「少数・短値・入れ子なし」の宣言だけを許す
    private static func validateProlog(_ rawData: Data) throws {
        // cooViewer-oxr.85 / Washi-yru: UTF-32・EBCDIC は ASCII バイト検査を
        // 迂回して libxml2 に巨大な内部実体を展開させるため、BOM・先頭
        // バイト列・XML 宣言のいずれで判明しても解析前に拒否する。
        if let encoding = unsupportedXMLEncoding(rawData) {
            throw EPUBError.malformed("\(encoding) XML is not supported")
        }
        // libxml2 が見るのと同じ文字列で検査する。UTF-16(BOM または
        // 交互の 0x00)は UTF-8 相当へ正規化する — さもないと ASCII バイト
        // リテラルを見るスキャナが DOCTYPE を素通しし、UTF-16 で書かれた
        // 実体爆弾がガードを丸ごと迂回する
        let data = try normalizedXMLBytes(rawData)
        guard let doctype = try internalDoctypeSlice(data) else { return }
        // 引用状態を追う走査で得た内部サブセットだけを検査する。
        // 引用内のコメント/PI 区切りを宣言境界をまたいで結ぶと、
        // 間にある危険な宣言が除去され、検査を迂回されてしまう。
        let text = doctype.internalSubset
        guard text.contains("<!ENTITY") else { return }
        // 宣言の形は「名前 + 引用値」のみ許可(SYSTEM/PUBLIC/NDATA/
        // パラメータ実体 % は不許可 — 外部実体は読まないので宣言ごと拒否)
        var count = 0
        var searchFrom = text.startIndex
        while let range = text.range(of: "<!ENTITY", range: searchFrom..<text.endIndex) {
            searchFrom = range.upperBound
            count += 1
            guard count <= 64 else {
                throw EPUBError.malformed("内部 DTD の実体宣言が多すぎる")
            }
            let declaration = text[range.lowerBound...]
            guard let match = declaration.prefixMatch(
                of: /<!ENTITY\s+([^\s%>]+)\s+(?:"([^"]*)"|'([^']*)')\s*>/),
                  isSafeEntityValue(String(match.2 ?? match.3 ?? "")) else {
                throw EPUBError.malformed("内部 DTD に危険な実体宣言がある")
            }
        }
    }

    private static func unsupportedXMLEncoding(_ data: Data) -> String? {
        let head = Array(data.prefix(4))
        if head.count == 4 {
            // 通常の UTF-32 BOM、XML 1.0 が定義する BOM なしの先頭 '<'、
            // および稀な UCS-4 2143/3412 バイト順をすべて安全側で扱う。
            // Washi-yru: libxml2 xmlDetectCharEncoding の全分岐(UCS-4 4 種・UTF-16 BOM・UTF-8 BOM・EBCDIC)を拒否または後段で検査する。
            let signatures: [(bytes: [UInt8], encoding: String)] = [
                ([0xFF, 0xFE, 0x00, 0x00], "UTF-32"), ([0x00, 0x00, 0xFE, 0xFF], "UTF-32"),
                ([0x3C, 0x00, 0x00, 0x00], "UTF-32"), ([0x00, 0x00, 0x00, 0x3C], "UTF-32"),
                ([0x00, 0x00, 0x3C, 0x00], "UTF-32"), ([0x00, 0x3C, 0x00, 0x00], "UTF-32"),
                ([0x00, 0x00, 0xFF, 0xFE], "UTF-32"), ([0xFE, 0xFF, 0x00, 0x00], "UTF-32"),
                ([0x4C, 0x6F, 0xA7, 0x94], "EBCDIC"),
            ]
            if let match = signatures.first(where: { $0.bytes == head }) {
                return match.encoding
            }
        }
        guard let name = XMLCharsetDetector.declaredCharsetName(
            in: data, includesHTMLMeta: false)
        else { return nil }
        let normalized = name.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized.hasPrefix("utf32") || normalized.hasPrefix("ucs4") ? "UTF-32" : nil
    }

    /// 実体値の安全判定: 64 バイト以下で、`&` は「文字参照 `&#…;`」または
    /// 「XML 定義済み 5 実体(amp/lt/gt/quot/apos)」のみ許可。これらは
    /// 再帰展開しないので指数爆発の入口にならない。一般実体参照 `&name;` は
    /// 不許可。`&#38;`(&)・`&#37;`(%)・`&amp;` は宣言済み値へ後から参照を
    /// 密輸する抜け道になるため数値・実体いずれの形でも不許可
    private static func isSafeEntityValue(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let predefinedSafe: Set<String> = ["lt", "gt", "quot", "apos"]
        var rest = Substring(value)
        while let amp = rest.firstIndex(of: "&") {
            let after = rest[amp...]
            if let match = after.prefixMatch(
                of: /&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});/) {
                let number = match.1
                let scalar = number.hasPrefix("x")
                    ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                guard let scalar, scalar != 0x26, scalar != 0x25 else { return false }
                rest = after[match.range.upperBound...]
            } else if let match = after.prefixMatch(of: /&([a-zA-Z]+);/),
                      predefinedSafe.contains(String(match.1)) {
                rest = after[match.range.upperBound...]
            } else {
                return false  // 一般実体参照・&amp;・不正形は不許可
            }
        }
        return true
    }

    /// UTF-16(BOM 付き、または BOM なしで交互に 0x00 が入る)を UTF-8 の
    /// バイト列へ変換する。それ以外(UTF-8・Shift_JIS 等の ASCII 上位互換)は
    /// そのまま返す。DOCTYPE スキャナが ASCII リテラルで動くための正規化
    private static func normalizedXMLBytes(_ data: Data) throws -> Data {
        func toUTF8(_ encoding: String.Encoding, skippingBOM: Int) throws -> Data {
            // 復号できない UTF-16 を生バイトで返すと ASCII の DTD 検査を
            // 素通りし、libxml2 だけが実体宣言を解釈するため拒否する。
            guard let text = String(data: data.dropFirst(skippingBOM), encoding: encoding)
            else { throw EPUBError.malformed("UTF-16 XML を復号できない") }
            return Data(text.utf8)
        }
        let head = Array(data.prefix(4))
        if head.count >= 2 {
            if head[0] == 0xFF, head[1] == 0xFE {
                return try toUTF8(.utf16LittleEndian, skippingBOM: 2)
            }
            if head[0] == 0xFE, head[1] == 0xFF {
                return try toUTF8(.utf16BigEndian, skippingBOM: 2)
            }
        }
        // BOM なし UTF-16 は先頭 '<'(0x3C)が 0x00 と対になる
        if head.count >= 2 {
            if head[0] == 0x3C, head[1] == 0x00 {
                return try toUTF8(.utf16LittleEndian, skippingBOM: 0)
            }
            if head[0] == 0x00, head[1] == 0x3C {
                return try toUTF8(.utf16BigEndian, skippingBOM: 0)
            }
        }
        return data
    }

    /// DOCTYPE 宣言全体のスライスと、コメント・PI を除いた内部サブセットを返す。
    /// コメント・処理命令を正しく飛ばし、DOCTYPE 内は引用文字列・コメント・
    /// 内部サブセット [ ] を追跡して終端 `>` を決める(引用中の `]>` 等で
    /// 早期終了して以降の宣言を見逃さないため)
    private static func internalDoctypeSlice(_ data: Data) throws
        -> (doctype: Data, internalSubset: String)? {
        // cooViewer-oxr.86: 未終端 DOCTYPE を後段の正規表現へ無制限に渡さない。
        // 1 回の前向き走査を 64 KiB で打ち切り、入力長に依存する二乗時間を防ぐ。
        let maxDoctypeByteCount = 64 * 1024
        var i = data.startIndex
        let lt = UInt8(ascii: "<")
        func matches(_ literal: String, at index: Data.Index) -> Bool {
            let bytes = Array(literal.utf8)
            guard data.distance(from: index, to: data.endIndex) >= bytes.count
            else { return false }
            for (offset, byte) in bytes.enumerated()
            where data[data.index(index, offsetBy: offset)] != byte {
                return false
            }
            return true
        }
        while i < data.endIndex {
            guard data[i] == lt else {
                i = data.index(after: i)
                continue
            }
            if matches("<?", at: i) {
                // 処理命令・XML 宣言: "?>" まで飛ばす
                guard let end = data[i...].firstRange(of: Data("?>".utf8))
                else { return nil }
                i = end.upperBound
            } else if matches("<!--", at: i) {
                guard let end = data[i...].firstRange(of: Data("-->".utf8))
                else { return nil }
                i = end.upperBound
            } else if matches("<!DOCTYPE", at: i) {
                let start = i
                var j = data.index(i, offsetBy: 9)
                var quote: UInt8? = nil
                var subsetDepth = 0
                var inComment = false
                var inProcessingInstruction = false
                var subset = Data()
                while j < data.endIndex {
                    guard data.distance(from: start, to: j) < maxDoctypeByteCount else {
                        throw EPUBError.malformed(
                            "DOCTYPE exceeds the 65536-byte safety limit")
                    }
                    let byte = data[j]
                    let wasInSubset = subsetDepth > 0
                    if inComment {
                        if matches("-->", at: j) {
                            inComment = false
                            j = data.index(j, offsetBy: 3)
                            continue
                        }
                    } else if inProcessingInstruction {
                        if matches("?>", at: j) {
                            inProcessingInstruction = false
                            j = data.index(j, offsetBy: 2)
                            continue
                        }
                    } else if let q = quote {
                        if byte == q { quote = nil }
                    } else if matches("<!--", at: j) {
                        // 除去したコメント/PI の両側を連結して、元にない
                        // 宣言トークンを作らないよう空白を残す。
                        if wasInSubset { subset.append(UInt8(ascii: " ")) }
                        inComment = true
                        j = data.index(j, offsetBy: 4)
                        continue
                    } else if matches("<?", at: j) {
                        // 内部サブセット内の処理命令。PI 内の `]` や `>` に
                        // 騙されて DOCTYPE を早期終了しないよう "?>" まで飛ばす
                        if wasInSubset { subset.append(UInt8(ascii: " ")) }
                        inProcessingInstruction = true
                        j = data.index(j, offsetBy: 2)
                        continue
                    } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                        quote = byte
                    } else if byte == UInt8(ascii: "[") {
                        subsetDepth += 1
                    } else if byte == UInt8(ascii: "]") {
                        subsetDepth = max(0, subsetDepth - 1)
                    } else if byte == UInt8(ascii: ">"), subsetDepth == 0 {
                        guard let text = String(data: subset, encoding: .utf8) else {
                            // Washi-yru: < (0x3C) は Shift_JIS/EUC-JP の trail byte に
                            // 現れないため、生バイトで実体宣言の有無を判定できる。
                            // 実体を含まない非 UTF-8 の宣言は検査対象から外す。
                            guard subset.firstRange(of: Data("<!ENTITY".utf8)) == nil else {
                                throw EPUBError.malformed("DTD の文字コードを判定できない")
                            }
                            return (data[start...j], "")
                        }
                        return (data[start...j], text)
                    }
                    // 外部 ID のリテラルと外側の [ ] は含めず、本物の
                    // コメント/PI だけを省く。引用内の区切りは値として残す。
                    if wasInSubset, subsetDepth > 0, !inComment, !inProcessingInstruction {
                        subset.append(byte)
                    }
                    j = data.index(after: j)
                }
                throw EPUBError.malformed("Unterminated DOCTYPE declaration")
            } else {
                return nil  // ルート要素(または他の <! 構文)に到達: DTD なし
            }
        }
        return nil
    }

    /// cooViewer-oxr.10/13: WHATWG 表にある HTML 名前実体を 1 回の走査で探す。
    /// & (0x26) は Shift_JIS/EUC-JP の trail byte 範囲に入らないため、
    /// 非 UTF-8 のまま走査しても ASCII の実体名を誤認しない。
    private static func containsNamedEntity(_ data: Data) throws -> Bool {
        let normalized = try normalizedXMLBytes(data)
        return normalized.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                guard bytes[index] == UInt8(ascii: "&") else {
                    index += 1
                    continue
                }
                let nameStart = index + 1
                guard nameStart < bytes.count, isASCIIEntityNameStart(bytes[nameStart])
                else {
                    index += 1
                    continue
                }
                var cursor = nameStart + 1
                while cursor < bytes.count,
                      cursor - nameStart < 32,
                      isASCIIEntityNameContinuation(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";") {
                    let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)
                    if HTMLEntities.table[name] != nil { return true }
                }
                index += 1
            }
            return false
        }
    }

    /// cooViewer-oxr.10/13: XML 定義済み 5 実体以外の HTML 実体を、
    /// 1 回の走査で数値文字参照へ置換する。未知の実体名は変更しない。
    /// 非 UTF-8(Shift_JIS/EUC-JP/UTF-16)の文書でも救済できるよう、宣言の
    /// encoding を尊重して復号してから置換し、UTF-8 で再エンコードする
    private static func sanitizeEntities(_ rawData: Data) throws -> Data {
        // UTF-16 は先に UTF-8 バイトへ畳む
        let data = try normalizedXMLBytes(rawData)
        guard let text = decodeXMLText(data) else { return data }
        let sanitized = replacingNamedEntities(in: text)
        // 出力バイトは UTF-8。宣言の encoding が別物のままだと再パースが
        // "switching encoding" で失敗するため、宣言も UTF-8 に書き換える
        return Data(rewriteXMLEncodingToUTF8(sanitized).utf8)
    }

    /// cooViewer-oxr.12: UTF-8 を優先し、不正な場合だけ共有 detector が
    /// XML 宣言、meta charset、http-equiv の順で見つけた文字コードを使う。
    private static func decodeXMLText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        guard let encoding = XMLCharsetDetector.declaredEncoding(in: data) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }

    private static func replacingNamedEntities(in text: String) -> String {
        let input = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var unchangedStart = 0
        var index = 0
        while index < input.count {
            guard input[index] == UInt8(ascii: "&") else {
                index += 1
                continue
            }
            let nameStart = index + 1
            guard nameStart < input.count, isASCIIEntityNameStart(input[nameStart])
            else {
                index += 1
                continue
            }
            var cursor = nameStart + 1
            while cursor < input.count,
                  cursor - nameStart < 32,
                  isASCIIEntityNameContinuation(input[cursor]) {
                cursor += 1
            }
            guard cursor < input.count, input[cursor] == UInt8(ascii: ";"),
                  let replacement = HTMLEntities.table[
                    String(decoding: input[nameStart..<cursor], as: UTF8.self)]
            else {
                index += 1
                continue
            }
            output.append(contentsOf: input[unchangedStart..<index])
            output.append(contentsOf: replacement.utf8)
            index = cursor + 1
            unchangedStart = index
        }
        output.append(contentsOf: input[unchangedStart...])
        return String(decoding: output, as: UTF8.self)
    }

    private static func isASCIIEntityNameStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isASCIIEntityNameContinuation(_ byte: UInt8) -> Bool {
        isASCIIEntityNameStart(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// 先頭 XML 宣言内の encoding 属性を UTF-8 へ書き換える(宣言が無ければ無変更)
    private static func rewriteXMLEncodingToUTF8(_ text: String) -> String {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else {
            return text
        }
        let declaration = text[text.startIndex..<end.upperBound]
        let rewritten = declaration.replacing(
            /encoding\s*=\s*["'][^"'<>]+["']/, with: "encoding=\"UTF-8\"")
        return String(rewritten) + String(text[end.upperBound...])
    }
}
