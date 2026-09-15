import Foundation

// 表示・実測・サムネイルで同じ項目のフローを使う。
extension EPUBPublication {
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
        guard readingOrder.indices.contains(index) else { return index..<index }
        guard renderingFlow(at: index) == .scrolledContinuous else { return index..<(index + 1) }
        var lower = index
        var upper = index + 1
        while lower > 0, renderingFlow(at: lower - 1) == .scrolledContinuous { lower -= 1 }
        while upper < readingOrder.count, renderingFlow(at: upper) == .scrolledContinuous { upper += 1 }
        return lower..<upper
    }
}
