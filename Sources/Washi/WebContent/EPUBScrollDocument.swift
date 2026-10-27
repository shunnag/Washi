import AppKit
import WebKit

// 章ごとの DOM/CSS と本文の UTF-16 写像を保ち、1 つのスクロール文書へ配置する。
@MainActor
enum EPUBScrollDocument {
    // Washi-1nm: roll は実在の漫画で数百ページなので、正確な寸法は 2,048 件まで。
    // ただし 1 MiB 章の実測 0.0319 秒を件数だけ掛けると長時間停止するため、
    // 展開量も 28 MiB に制限する(同規模の章は 27 件、解析は約 0.86 秒)。
    // Corpus の画像 spine の roll 本(9 項目・計約 25.4 MiB)も寸法を保ち、
    // 残りの setup・JSON 生成にも時間を残す。
    static let maximumExactDimensionItems = 2_048
    static let maximumDimensionBytes = 28 * 1_024 * 1_024

    static let containerData = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Washi</title></head><body/></html>
        """.utf8)

    static func install(in controller: WKUserContentController, handler: EPUBSchemeHandler) {
        let path = "/" + handler.scrollDocumentPath
        let source = """
        (function () {
            if (window === window.top && location.pathname === '\(path)') {
                \(ReaderScripts.continuousScrollScript)
                return;
            }
            if (window !== window.top && !window.parent.__washiScrollContainer) { return; }
            \(ReaderScripts.pageScript)
            \(ReaderScripts.baseCSSInjector)
        })();
        """
        controller.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: WashiContentWorld.world))
    }

    static func options(_ json: String, publication: EPUBPublication,
                        index: Int, handler: EPUBSchemeHandler,
                        onlyItem: Bool = false) -> String {
        guard publication.renderingFlow(at: index) == .scrolledContinuous,
              let data = json.data(using: .utf8),
              var options = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        let group = onlyItem
            ? (range: index..<(index + 1), flow: RenditionFlow.scrolledContinuous)
            : publication.scrollConfiguration(containing: index)
        let range = group.range
        // roll を含む巨大 group は章単位スクロールへ縮退する。paginated と違い
        // 既存のスクロール操作・単一カラムを保て、JS へ渡す iframe も 1 件になる。
        options[.flow] = group.flow.rawValue
        let width = (options[.width] as? Double) ?? 400
        let height = (options[.height] as? Double) ?? 600
        var remainingItems = maximumExactDimensionItems
        var remainingBytes = maximumDimensionBytes
        options[.spineIndex] = index
        options[.continuousItems] = range.compactMap { itemIndex -> [String: Any]? in
            let entry = publication.readingOrder[itemIndex]
            guard let url = handler.url(forReadingOrderItem: entry) else { return nil }
            let layout = publication.package.effectiveLayout(for: entry.itemRef)
            let roll = layout == .roll || layout == .prePaginated
            var item: [String: Any] = [
                "index": itemIndex, "url": url.absoluteString, "roll": roll,
                "renderable": publication.canRenderSpineResource(entry)
            ]
            if roll {
                var info = publication.cachedFixedLayoutInfo(forSpineIndex: itemIndex)
                if info == nil, remainingItems > 0, remainingBytes > 0 {
                    remainingItems -= 1
                    info = try? publication.fixedLayoutInfo(
                        forSpineIndex: itemIndex, remainingByteCount: &remainingBytes)
                }
                let size = info?.viewportIsDeviceSized == true
                    ? CGSize(width: width, height: height)
                    : (info?.viewportSize ?? CGSize(width: 1200, height: 1600))
                // 非有限・非正数は既存の固定レイアウトと同じ既定寸法へ戻す。
                item["width"] = size.width.isFinite && size.width >= 1 ? size.width : 1200
                item["height"] = size.height.isFinite && size.height >= 1 ? size.height : 1600
            }
            return item
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        else { return json }
        return String(data: encoded, encoding: .utf8) ?? json
    }
}
