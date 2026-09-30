import Foundation

enum SMILParser {
    static func parse(data: Data, at containerPath: String) throws -> MediaOverlay {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("SMIL が壊れている: \(containerPath)")
        }
        var parallels: [MediaOverlay.Parallel] = []
        collectParallels(in: root, into: &parallels)
        return MediaOverlay(parallels: parallels, basePath: containerPath)
    }

    private static func collectParallels(
        in element: XMLElement, inheritedTypes: [String] = [],
        into result: inout [MediaOverlay.Parallel]) {
        var types = inheritedTypes
        if let own = element.attr("type", ns: XMLNamespace.epubOps, prefix: "epub") {
            types.append(own)
        }
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == "par" {
                let text = child.wsFirst("text", ns: XMLNamespace.smil)?.attr("src")
                let audio = child.wsFirst("audio", ns: XMLNamespace.smil)
                let parTypes = types + [child.attr("type", ns: XMLNamespace.epubOps,
                                                 prefix: "epub")].compactMap { $0 }
                result.append(MediaOverlay.Parallel(
                    textHref: text,
                    audioHref: audio?.attr("src"),
                    clipBegin: audio?.attr("clipBegin")
                        .flatMap(parseClockValue) ?? 0,
                    clipEnd: audio?.attr("clipEnd").flatMap(parseClockValue),
                    epubType: parTypes.isEmpty ? nil : parTypes.joined(separator: " ")))
            } else {
                // seq(と body)は再帰的に順序どおり平坦化する
                collectParallels(in: child, inheritedTypes: types, into: &result)
            }
        }
    }

    /// SMIL クロック値("12.5s" / "1:02:03.5" / "02:03" / "1250ms")→ 秒。
    /// NaN・Inf・負値(細工/雑な SMIL の "nan"・"1e999s"・"-5s" 等)は nil を返し
    /// 省略扱いにする — AVAudioPlayer.currentTime へ不正値を渡すとシーク破綻・
    /// クリップ終端判定の恒偽化(ティッカーの空回り)を招くため
    static func parseClockValue(_ text: String) -> Double? {
        // NaN は `>= 0` が false になるので、この 1 つの検査で NaN/Inf/負を弾ける
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("ms") {
            return valid(Double(trimmed.dropLast(2)).map { $0 / 1000 })
        }
        if trimmed.hasSuffix("s") {
            return valid(Double(trimmed.dropLast()))
        }
        if trimmed.hasSuffix("min") {
            return valid(Double(trimmed.dropLast(3)).map { $0 * 60 })
        }
        if trimmed.hasSuffix("h") {
            return valid(Double(trimmed.dropLast()).map { $0 * 3600 })
        }
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return valid(hours * 3600 + minutes * 60 + seconds)
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return valid(minutes * 60 + seconds)
        case 1:
            return valid(Double(parts[0]))
        default:
            return nil
        }
    }
}
