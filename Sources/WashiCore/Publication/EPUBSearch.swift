import Foundation

/// EPUB の全文検索で使う比較方法のオプション。
///
/// Options that control EPUB full-text search comparison.
public struct EPUBSearchOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// 大文字と小文字を区別して一致を判定する。
    ///
    /// Require matching letter case.
    public static let caseSensitive = EPUBSearchOptions(rawValue: 1 << 0)
    /// ダイアクリティカルマークを区別して一致を判定する。
    ///
    /// Require matching diacritics.
    public static let diacriticSensitive = EPUBSearchOptions(rawValue: 1 << 1)
    /// 全角・半角を厳密に区別して一致を判定する。
    ///
    /// Require character widths to match exactly.
    public static let widthSensitive = EPUBSearchOptions(rawValue: 1 << 2)
}

/// 出版物内の全文検索の一致結果。
///
/// A full-text search hit within a publication.
public struct EPUBSearchHit: Sendable, Equatable {
    /// 一致箇所を含む spine 項目のインデックス(読む順序での位置)。
    ///
    /// Index of the spine item (reading-order position) containing the match.
    public let spineIndex: Int
    /// 項目から抽出した本文内の、一致箇所の文字オフセット。
    /// 後からハイライトするときの安定した錨として使える。
    ///
    /// Character offset of the match within the item's extracted plain text.
    /// Suitable as a stable anchor for later highlighting.
    public let characterOffset: Int
    /// 一致したテキストの長さ(文字単位)。
    ///
    /// Length of the matched text, in characters.
    public let length: Int
    /// 抽出本文内の一致範囲(UTF-16 コード単位)。
    ///
    /// Match range in the extracted text, measured in UTF-16 code units.
    public let utf16Range: Range<Int>
    /// 一致箇所を中央に含む、周囲の本文の短い抜粋。
    ///
    /// A short excerpt of surrounding text, with the match in the middle.
    public let snippet: String

    /// 文字単位のオフセットを使って一致結果を作成する。
    ///
    /// Creates a hit using character-based offsets.
    ///
    /// 指定されたオフセットと長さから UTF-16 範囲を導く。元の本文に複数の
    /// UTF-16 コード単位で表される文字が含まれる場合は、
    /// ``init(spineIndex:characterOffset:length:utf16Range:snippet:)`` を使う。
    ///
    /// The UTF-16 range is derived from the supplied offset and length. Use
    /// ``init(spineIndex:characterOffset:length:utf16Range:snippet:)`` when the
    /// source text contains characters represented by multiple UTF-16 units.
    public init(spineIndex: Int, characterOffset: Int,
                length: Int, snippet: String) {
        let (sum, overflow) = characterOffset.addingReportingOverflow(length)
        let upperBound = length <= 0 ? characterOffset : (overflow ? Int.max : sum)
        self.init(spineIndex: spineIndex, characterOffset: characterOffset,
                  length: length,
                  utf16Range: characterOffset..<upperBound,
                  snippet: snippet)
    }

    /// 文字単位と UTF-16 コード単位の両方のオフセットを持つ一致結果を作成する。
    ///
    /// Creates a hit with both character-based and UTF-16 offsets.
    public init(spineIndex: Int, characterOffset: Int, length: Int,
                utf16Range: Range<Int>, snippet: String) {
        self.spineIndex = spineIndex
        self.characterOffset = characterOffset
        self.length = length
        self.utf16Range = utf16Range
        self.snippet = snippet
    }
}

extension EPUBPublication {
    /// 出版物全体から部分文字列を、読む順序に沿って検索する。
    ///
    /// Searches the whole publication for a substring, in reading order.
    ///
    /// 各 spine 項目を ``extractText(forSpineIndex:)`` で抽出し、`query` を探す。
    /// 既定では大文字・小文字、ダイアクリティカルマーク、全角・半角を区別しない。
    /// すべての一致箇所を返す。
    ///
    /// Each spine item is extracted with ``extractText(forSpineIndex:)`` and
    /// scanned for `query`. The default comparison is case-, diacritic-, and
    /// width-insensitive. Returns every occurrence.
    ///
    /// 呼び出し元のコンテキストで実行する。未キャッシュのコンテンツ項目は
    /// 初回利用時に解析するため、大きな本ではメインアクター以外からの呼び出しを
    /// 推奨する。現在のタスクがキャンセルされた場合は途中で止め、それまでに
    /// 見つかった一致結果を返す。
    ///
    /// This runs on the calling context; uncached content items are parsed on
    /// first use, so for a large book prefer calling it off the main actor.
    /// If the current task is cancelled, it stops early and returns the hits
    /// found so far.
    ///
    /// - Parameters:
    ///   - query: 探すテキスト。空または空白だけなら一致結果は返さない。
    ///     the text to find. Empty or whitespace-only returns no hits.
    ///   - snippetRadius: ``EPUBSearchHit/snippet`` に含める、一致箇所の前後
    ///     それぞれの文脈の文字数。
    ///     how many characters of context to include on each
    ///     side of a match in ``EPUBSearchHit/snippet``.
    /// - Returns: spine index、次いでオフセットの順に並べた一致結果。
    ///   hits ordered by spine index, then by offset.
    public func search(_ query: String,
                       snippetRadius: Int = 24) -> [EPUBSearchHit] {
        search(query, options: [], snippetRadius: snippetRadius)
    }

    /// 比較オプションを指定して、出版物全体を検索する。
    ///
    /// Searches the whole publication using configurable comparison options.
    ///
    /// 全角・半角を区別しない場合は、半角濁点カナ(例: `ｶﾞ`)を互換正規化する。
    /// 検索の空白は、抽出したインラインテキストと同じ方法で正規化するため、
    /// 全角スペースと改行しないスペースも通常のスペースに一致する。
    ///
    /// Half-width voiced kana (for example `ｶﾞ`) are compatibility-folded when
    /// width-sensitive comparison is not requested. Search whitespace is
    /// normalized in the same way as extracted inline text, so ideographic and
    /// nonbreaking spaces match ordinary spaces.
    ///
    /// - Parameters:
    ///   - query: 探すテキスト。空または空白だけなら一致結果は返さない。
    ///     the text to find. Empty or whitespace-only returns no hits.
    ///   - options: 比較時に区別する要素。空の集合なら、既定の動作と同じく
    ///     大文字・小文字、ダイアクリティカルマーク、全角・半角を区別しない。
    ///     comparison sensitivities. An empty set preserves the
    ///     default case-, diacritic-, and width-insensitive behavior.
    ///   - snippetRadius: ``EPUBSearchHit/snippet`` に含める、一致箇所の前後
    ///     それぞれの文脈の文字数。
    ///     how many characters of context to include on each
    ///     side of a match in ``EPUBSearchHit/snippet``.
    /// - Returns: spine index、次いでオフセットの順に並べた一致結果。
    ///   hits ordered by spine index, then by offset.
    public func search(_ query: String, options: EPUBSearchOptions,
                       snippetRadius: Int = 24) -> [EPUBSearchHit] {
        // cooViewer-oxr.11: 本文と同じ正規化を使い、段落改行も同じ形で保つ。
        let needle = Self.collapsingWhitespace(query)
        guard !needle.isEmpty else { return [] }
        // cooViewer-oxr.11: 負の radius は範囲を反転させるため非負へ丸める。
        let radius = max(0, snippetRadius)
        var hits: [EPUBSearchHit] = []
        for index in readingOrder.indices {
            // cooViewer-gic: 呼び出し側が世代交代で捨てた検索を全文走査し続けない。
            if Task.isCancelled { break }
            guard let text = try? extractText(forSpineIndex: index),
                  !text.isEmpty else { continue }
            hits.append(contentsOf: Self.matches(
                of: needle, in: text, spineIndex: index,
                options: options, snippetRadius: radius))
        }
        return hits
    }

    // MARK: - 実装

    /// cooViewer-oxr.11: 検索用の 1 文字畳み込み。半角濁点カナ(ｶﾞ 等)は 1 書記素で、
    /// widthInsensitive では全角(ガ)に畳まれず取りこぼす。全角/半角形ブロック
    /// (U+FF00–FFEF)を含む文字だけ NFKC で畳んで全角化する(1 文字に畳める
    /// ものだけ。稀な合字は 1:1 を保つためそのまま)。他の文字は素通しなので、
    /// 通常のテキストでは畳み結果=原文(既存挙動は不変)で高速
    private static func foldForSearch(_ c: Character) -> Character {
        guard c.unicodeScalars.contains(where: { (0xFF00...0xFFEF).contains($0.value) })
        else { return c }
        let n = String(c).precomposedStringWithCompatibilityMapping
        return n.count == 1 ? n.first! : c
    }

    /// cooViewer-oxr.11: query の出現位置を全て返す。比較指定に応じて大小・
    /// 濁点・全半角・半角濁点カナを無視する。畳み込み後に隣接書記素が
    /// 結合する場合も、検索位置は元テキストの文字境界へ写像して返す。
    private static func matches(of needle: String, in text: String,
                                spineIndex: Int,
                                options searchOptions: EPUBSearchOptions,
                                snippetRadius: Int) -> [EPUBSearchHit] {
        guard !Task.isCancelled else { return [] }
        let widthSensitive = searchOptions.contains(.widthSensitive)
        // 全角/半角形の UTF-8 は必ず 0xEF で始まる。不在なら畳み込みと配列化を省く。
        let foldedChars: [Character]?
        if !widthSensitive && text.utf8.contains(0xEF) {
            // 長い単一章でも、取消後に全体を畳み込み続けない。
            var processed = 0
            do {
                foldedChars = try text.map { character in
                    if processed.isMultiple(of: 1024) { try Task.checkCancellation() }
                    processed += 1
                    return Self.foldForSearch(character)
                }
            } catch { return [] }
        } else {
            foldedChars = nil
        }
        let foldedText = foldedChars.map { String($0) } ?? text
        let foldedNeedle = widthSensitive
            ? needle : String(needle.map(Self.foldForSearch))
        guard !foldedNeedle.isEmpty else { return [] }
        var comparisonOptions: String.CompareOptions = []
        if !searchOptions.contains(.caseSensitive) {
            comparisonOptions.insert(.caseInsensitive)
        }
        if !searchOptions.contains(.diacriticSensitive) {
            comparisonOptions.insert(.diacriticInsensitive)
        }
        if !widthSensitive {
            comparisonOptions.insert(.widthInsensitive)
        }
        // 初ヒットがなければ、原文の文字配列と位置写像は不要。
        // 畳み込み済みの本文・検索語と同じ比較指定で判定し、偽陰性を生まない。
        guard !Task.isCancelled,
              var range = foldedText.range(of: foldedNeedle, options: comparisonOptions),
              !Task.isCancelled
        else { return [] }
        let chars = Array(text)
        // 元の文字ごとに、原文と畳み込み後の UTF-16 前方和を対応付ける。
        // 半角ハングル等は連結後に書記素が結合するため、文字数では対応を保てない。
        var utf16Offsets: [Int] = [0]
        utf16Offsets.reserveCapacity(chars.count + 1)
        for character in chars {
            if utf16Offsets.count.isMultiple(of: 1024), Task.isCancelled { return [] }
            utf16Offsets.append(utf16Offsets.last! + character.utf16.count)
        }
        let foldedUTF16Offsets: [Int]
        if let foldedChars {
            var offsets: [Int] = [0]
            offsets.reserveCapacity(foldedChars.count + 1)
            for character in foldedChars {
                if offsets.count.isMultiple(of: 1024), Task.isCancelled { return [] }
                offsets.append(offsets.last! + character.utf16.count)
            }
            foldedUTF16Offsets = offsets
        } else {
            foldedUTF16Offsets = utf16Offsets
        }
        var hits: [EPUBSearchHit] = []
        var searchStart = foldedText.startIndex
        // UTF-16 位置と写像の走査位置を増分で進め、各ヒットで先頭から数え直さない。
        var baseUTF16Offset = 0
        var offset = 0
        var matchEnd = 0
        while true {
            // ヒット数に比例する処理も章内で中断し、取消確認の負担はまとめる。
            if hits.count.isMultiple(of: 64), Task.isCancelled { break }
            let foldedLower = baseUTF16Offset
                + foldedText.utf16.distance(from: searchStart, to: range.lowerBound)
            let foldedUpper = foldedLower
                + foldedText.utf16.distance(from: range.lowerBound, to: range.upperBound)
            // 公開 API の錨は原文上の位置なので、全半角を区別しない検索を維持したまま
            // 元の文字範囲へ戻す。境界が文字の内部なら、その文字全体を含める。
            while offset < chars.count, foldedUTF16Offsets[offset + 1] <= foldedLower {
                offset += 1
            }
            while matchEnd < chars.count, foldedUTF16Offsets[matchEnd] < foldedUpper {
                matchEnd += 1
            }
            let length = matchEnd - offset
            let lower = offset - min(offset, snippetRadius)
            let upper = matchEnd + min(chars.count - matchEnd, snippetRadius)
            let snippet = String(chars[lower..<upper])
            let utf16Range = utf16Offsets[offset]..<utf16Offsets[matchEnd]
            hits.append(EPUBSearchHit(spineIndex: spineIndex,
                                      characterOffset: offset,
                                      length: length,
                                      utf16Range: utf16Range,
                                      snippet: snippet))
            // 次の探索は今回のマッチ末尾から(ゼロ幅は起きない=needle 非空)
            searchStart = range.upperBound
            baseUTF16Offset = foldedUpper
            guard let nextRange = foldedText.range(of: foldedNeedle,
                                                   options: comparisonOptions,
                                                   range: searchStart..<foldedText.endIndex)
            else { break }
            range = nextRange
        }
        return hits
    }
}
