import WebKit

/// cooViewer-oxr.35: WebKit の native menu を policy/delegate 経路へ渡す
/// WKWebView。返却 menu が別インスタンスなら表示対象へ項目を移す。
@MainActor
final class WashiWebView: WKWebView {
    var contextMenuHandler: ((NSMenu, NSEvent) -> NSMenu?)?

    /// ページ表示のホイールを WebKit より先に受ける回し先。true を返したら
    /// WebKit には渡さない(ジェスチャの始まりと終わりだけ移動量 0 の複製を渡す)。
    /// 縦書きの見開きで章の途中(scrollX が負)にいると、
    /// WebKit は wheel を DOM に渡さず自前でスクロールするため、JS では送れない。
    var wheelHandler: ((NSEvent) -> Bool)?

    /// テスト用: 受けたホイールの代わりに WebKit へ渡した移動量 0 の複製を見る
    /// (DOM には届かないため、テストはここで観測する)
    var didForwardGestureBoundaryForTest: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard wheelHandler?(event) == true else {
            super.scrollWheel(with: event)
            return
        }
        // WebKit の WebViewImpl::scrollWheel は phase が began のホイールで、本文に
        // 渡す前に辞書(調べる)のポップオーバーとデータ検出のバブルを閉じる。受けた
        // ホイールは WebKit に届かないので、ページが送られても開いたまま残る。
        // ジェスチャの始まりと終わり(ended/cancelled はジェスチャの状態をそろえる
        // ため)だけ、移動量を 0 にした複製を渡す(スクロールもページ送りも起きない)
        guard event.phase == .began || event.phase == .ended || event.phase == .cancelled,
              let boundary = Self.zeroDeltaCopy(of: event, windowOrigin: event.window?.frame.origin)
        else { return }
        didForwardGestureBoundaryForTest?(boundary)
        super.scrollWheel(with: boundary)
    }

    /// 位置と phase を保ったまま、スクロール量だけを 0 にしたホイールの複製。
    /// `windowOrigin` は元のイベントの窓の原点(画面座標)
    static func zeroDeltaCopy(of event: NSEvent, windowOrigin: NSPoint?) -> NSEvent? {
        guard let copy = event.cgEvent?.copy() else { return nil }
        for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                    .scrollWheelEventPointDeltaAxis1,
                                    .scrollWheelEventPointDeltaAxis2] {
            copy.setIntegerValueField(field, value: 0)
        }
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        // CGEvent から作る NSEvent は window が nil で、locationInWindow が画面座標に
        // なる。WebKit(PlatformEventFactoryMac の pointForEvent)は window を見ずに
        // それを窓座標として扱うので、元の窓座標になるようずらしておく
        if let origin = windowOrigin {
            copy.location.x -= origin.x
            copy.location.y += origin.y
        }
        return NSEvent(cgEvent: copy)
    }

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
