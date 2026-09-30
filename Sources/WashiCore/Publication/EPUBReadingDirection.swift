import Foundation

struct EffectiveReadingDirectionResolution: Sendable {
    let direction: EPUBReadingDirection
    let source: EPUBReadingDirectionSource
}

// cooViewer-oxr.36: EPUBPublication の Sendable 契約を保ったまま、CSS を含む
// 方向判定を最初の参照時に一度だけ実行する。
final class EffectiveReadingDirectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: EffectiveReadingDirectionResolution?

    func value(
        computing loader: () -> EffectiveReadingDirectionResolution
    ) -> EffectiveReadingDirectionResolution {
        lock.lock()
        defer { lock.unlock() }
        if let resolution { return resolution }
        let loaded = loader()
        resolution = loaded
        return loaded
    }
}

extension EPUBPublication {
    /// パッケージ・CSS・言語の情報を適用して決めた実効的な綴じ方向。
    ///
    /// The resolved reading direction after applying package, CSS, and language signals.
    ///
    /// ``readingDirection`` と異なり、必ず ``PageProgressionDirection/ltr`` または
    /// ``PageProgressionDirection/rtl`` となり、`default` にはならない。
    ///
    /// Unlike ``readingDirection``, this value is always ``PageProgressionDirection/ltr``
    /// or ``PageProgressionDirection/rtl`` and never `default`.
    public var effectiveReadingDirection: EPUBReadingDirection {
        effectiveReadingDirectionResolution.direction
    }

    /// ``effectiveReadingDirection`` を決める根拠となった、出版物内の情報。
    ///
    /// The publication signal that selected ``effectiveReadingDirection``.
    public var effectiveReadingDirectionSource: EPUBReadingDirectionSource {
        effectiveReadingDirectionResolution.source
    }

    private var effectiveReadingDirectionResolution: EffectiveReadingDirectionResolution {
        effectiveReadingDirectionCache.value {
            computeEffectiveReadingDirection()
        }
    }

    /// cooViewer-oxr.36: 宣言値、Kindle メタ、冒頭 CSS、RTL 言語の順で
    /// 省略されたページ進行方向を決定する。
    private func computeEffectiveReadingDirection() -> EffectiveReadingDirectionResolution {
        switch readingDirection {
        case .ltr, .rtl:
            return EffectiveReadingDirectionResolution(
                direction: readingDirection,
                source: .declared)
        case .byDefault:
            break
        }

        if let writingMode = metadata.metaItems.first(where: {
            $0.refines == nil
                && $0.property.lowercased() == "primary-writing-mode"
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch writingMode {
            case "vertical-rl", "horizontal-rl":
                return EffectiveReadingDirectionResolution(
                    direction: .rtl,
                    source: .primaryWritingModeMeta)
            case "vertical-lr", "horizontal-lr":
                return EffectiveReadingDirectionResolution(
                    direction: .ltr,
                    source: .primaryWritingModeMeta)
            default:
                break
            }
        }

        if firstReadingOrderStylesUseVerticalRTL() {
            return EffectiveReadingDirectionResolution(
                direction: .rtl,
                source: .verticalWritingCSS)
        }

        if let primaryLanguage = metadata.languages.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-", maxSplits: 1)
            .first.map(String.init),
           Self.rtlLanguageCodes.contains(primaryLanguage) {
            return EffectiveReadingDirectionResolution(
                direction: .rtl,
                source: .rtlLanguage)
        }

        return EffectiveReadingDirectionResolution(
            direction: .ltr,
            source: .fallback)
    }

    private static let rtlLanguageCodes: Set<String> = [
        "ar", "he", "fa", "ur", "yi", "ps", "sd", "ug", "dv",
    ]

    /// cooViewer-oxr.36: 冒頭の XHTML 最大 3 項目が実際に読み込む style/link
    /// だけを見る。CSS セレクタの完全評価はせず、使用中シート内の宣言を方向の
    /// ヒューリスティックとして扱う。
    private func firstReadingOrderStylesUseVerticalRTL() -> Bool {
        let documents = readingOrder.lazy.filter {
            Self.normalizedMediaType($0.resolvedItem.mediaType) == EPUBMediaType.xhtml
        }.prefix(3)

        for item in documents {
            guard let data = try? resource(at: item.resolvedContainerPath).data,
                  let document = try? WashiXML.document(from: data),
                  let root = document.rootElement()
            else { continue }

            let html = root.localName?.lowercased() == "html"
                ? root : Self.firstDescendant("html", in: root)
            let body = html.flatMap { Self.firstDescendant("body", in: $0) }
            if [html?.attr("style"), body?.attr("style")]
                .compactMap({ $0 })
                .contains(where: Self.cssUsesVerticalRTL) {
                return true
            }

            let styles = Self.descendants("style", in: root)
                .compactMap(\.stringValue)
            if styles.contains(where: Self.cssUsesVerticalRTL) {
                return true
            }

            for link in Self.descendants("link", in: root) {
                let relationships = (link.attr("rel") ?? "")
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                guard relationships.contains("stylesheet"),
                      let href = link.attr("href"),
                      let path = ContainerPath.resolve(
                        base: item.resolvedContainerPath,
                        href: href),
                      let cssData = try? resource(at: path).data,
                      let css = Self.cssString(cssData),
                      Self.cssUsesVerticalRTL(css)
                else { continue }
                return true
            }
        }
        return false
    }

    private static func cssString(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }

    private static func cssUsesVerticalRTL(_ css: String) -> Bool {
        css.range(
            of: #"(?i)(?:^|[;{\s])(?:-(?:webkit|epub)-)?writing-mode\s*:\s*(?:vertical-rl|tb-rl)(?:\s|[;!}]|$)"#,
            options: .regularExpression) != nil
    }
}
