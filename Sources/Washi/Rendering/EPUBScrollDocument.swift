import AppKit
import WebKit

// 章ごとの DOM/CSS と本文の UTF-16 写像を保ち、1 つのスクロール文書へ配置する。
@MainActor
enum EPUBScrollDocument {
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
            forMainFrameOnly: false, in: EPUBReaderView.washiWorld))
    }

    static func options(_ json: String, publication: EPUBPublication,
                        index: Int, handler: EPUBSchemeHandler,
                        onlyItem: Bool = false) -> String {
        guard publication.renderingFlow(at: index) == .scrolledContinuous,
              let data = json.data(using: .utf8),
              var options = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        let range = onlyItem ? index..<(index + 1) : publication.scrollGroup(containing: index)
        let width = (options["width"] as? Double) ?? 400
        let height = (options["height"] as? Double) ?? 600
        options["spineIndex"] = index
        options["continuousItems"] = range.compactMap { itemIndex -> [String: Any]? in
            let entry = publication.readingOrder[itemIndex]
            guard let url = handler.url(forReadingOrderItem: entry) else { return nil }
            let layout = publication.package.effectiveLayout(for: entry.itemRef)
            let roll = layout == .roll || layout == .prePaginated
            var item: [String: Any] = [
                "index": itemIndex, "url": url.absoluteString, "roll": roll,
                "renderable": EPUBReaderView.canRenderSpineResource(entry, in: publication)
            ]
            if roll {
                let info = try? publication.fixedLayoutInfo(forSpineIndex: itemIndex)
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
