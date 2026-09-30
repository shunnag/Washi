import WebKit

/// cooViewer-oxr.35: WebKit の native menu を policy/delegate 経路へ渡す
/// WKWebView。返却 menu が別インスタンスなら表示対象へ項目を移す。
@MainActor
final class WashiWebView: WKWebView {
    var contextMenuHandler: ((NSMenu, NSEvent) -> NSMenu?)?
    private(set) var isHandlingKeyDown = false

    override func keyDown(with event: NSEvent) {
        let wasHandlingKeyDown = isHandlingKeyDown
        isHandlingKeyDown = true
        defer { isHandlingKeyDown = wasHandlingKeyDown }
        // WebKit の super.keyDown が親へ返すキーは既に DOM で処理済み。
        // 親が非ナビ設定でも didReceiveKey をもう一度呼ばないように区別する。
        super.keyDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let resolved = contextMenuHandler.map { $0(menu, event) } ?? menu
        guard let resolved else {
            menu.removeAllItems()
            return
        }
        if resolved !== menu {
            menu.removeAllItems()
            for item in resolved.items {
                resolved.removeItem(item)
                menu.addItem(item)
            }
        }
        guard !menu.items.isEmpty else { return }
        super.willOpenMenu(menu, with: event)
    }
}
