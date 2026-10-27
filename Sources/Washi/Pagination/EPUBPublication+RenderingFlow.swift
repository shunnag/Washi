import Foundation

/// 表示・実測・サムネイルで同じ項目のフローを使う。
extension EPUBPublication {
    // Washi-1nm: Corpus 251 冊で連続表示を宣言する本は 7 冊、最大 spine は 9 項目。
    // 4,096 までは従来の連続表示を保ち、それ以上は setup の線形コストと
    // iframe 全件先読みを避けて、roll も章単位スクロールへ縮退する。
    static let maximumEagerScrollItems = 4_096

    func renderingFlow(at index: Int) -> RenditionFlow {
        guard readingOrder.indices.contains(index) else { return .auto }
        let item = readingOrder[index].itemRef
        let layout = package.effectiveLayout(for: item)
        let flow = package.effectiveFlow(for: item)
        if layout == .roll { return .scrolledContinuous }
        if layout == .prePaginated {
            // roll 導入前に使われた宣言も、同じ幅合わせの表示で扱う。
            return flow == .scrolledContinuous ? flow : .paginated
        }
        return flow
    }

    func scrollGroup(containing index: Int) -> Range<Int> {
        scrollConfiguration(containing: index).range
    }

    /// setup と章移動が同じ範囲を使い、縮退後に未読み込みの章へ JS 内で移動しない。
    func scrollConfiguration(containing index: Int) -> (range: Range<Int>, flow: RenditionFlow) {
        let flow = renderingFlow(at: index)
        guard readingOrder.indices.contains(index) else { return (index..<index, flow) }
        guard flow == .scrolledContinuous else { return (index..<(index + 1), flow) }
        var lower = index
        var upper = index + 1
        while lower > 0, renderingFlow(at: lower - 1) == .scrolledContinuous {
            lower -= 1
            if upper - lower > Self.maximumEagerScrollItems {
                return (index..<(index + 1), .scrolledDoc)
            }
        }
        while upper < readingOrder.count, renderingFlow(at: upper) == .scrolledContinuous {
            upper += 1
            if upper - lower > Self.maximumEagerScrollItems {
                return (index..<(index + 1), .scrolledDoc)
            }
        }
        return (lower..<upper, flow)
    }

    /// Core の公開 API を変えず、既に fallback 解決された項目の形式と実在性を
    /// 確認する。対応形式は Core の解決条件と揃え、未知形式を推測で許可しない。
    func canRenderSpineResource(_ entry: ReadingOrderItem) -> Bool {
        let mediaType = entry.resolvedItem.mediaType
            .split(separator: ";", maxSplits: 1).first.map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } ?? ""
        return (mediaType == EPUBMediaType.xhtml
                || EPUBMediaType.coreImageTypes.contains(mediaType))
            && resourceExists(at: entry.resolvedContainerPath)
    }
}
