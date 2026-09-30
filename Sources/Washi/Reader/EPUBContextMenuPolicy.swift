import AppKit

/// WebKit がリーダーのデリゲートへ渡すコンテキストメニューの操作を制御する。
///
/// Controls which contextual actions WebKit passes to the reader delegate.
///
/// ``EPUBReaderViewDelegate/readerView(_:willShowContextMenu:at:)`` が
/// 呼ばれる前に、WebKit のメニューをこの方針で絞り込む。デリゲートが
/// 設定されていれば、コンテキストメニューのイベントごとに必ず 1 回呼ばれる。
/// 絞り込みで項目がなくなった場合や、方針が ``suppressed`` の場合も同様。
/// デリゲートが `nil` または空のメニューを返すと表示を抑止する。
/// 空でないメニューを返せば、``suppressed`` でも表示する。
///
/// The policy filters WebKit's menu before
/// ``EPUBReaderViewDelegate/readerView(_:willShowContextMenu:at:)`` is called.
/// When a delegate is installed, it is called exactly once for every context-menu
/// event, including when filtering leaves no items and when the policy is
/// ``suppressed``. A delegate return value of `nil` or an empty menu suppresses
/// presentation. A non-empty returned menu is presented even under ``suppressed``.
public enum EPUBContextMenuPolicy: Sendable, Equatable {
    /// WebKit のシステムメニューをすべて使う。
    ///
    /// Uses WebKit's complete system menu.
    case system
    /// デリゲートによるカスタマイズの前に、WebKit が用意した項目をすべて除く。
    ///
    /// Removes every WebKit-provided item before delegate customization.
    case suppressed
    /// 識別子の raw value が許可されているメニュー項目だけを残す。
    ///
    /// Keeps only menu items whose identifier raw values are allowed.
    case allowing(identifiers: Set<String>)

    /// 読書向けのメニュー。利用可能な場合に、調べる、翻訳、コピー、
    /// Web 検索、読み上げの操作を含む。
    ///
    /// A reading-oriented menu containing lookup, translation, copy, web
    /// search, and speech actions when those actions are available.
    public static let readingDefault: EPUBContextMenuPolicy = .allowing(
        identifiers: [
            "WKMenuItemIdentifierLookUp",
            "WKMenuItemIdentifierTranslate",
            "WKMenuItemIdentifierCopy",
            "WKMenuItemIdentifierSearchWeb",
            "WKMenuItemIdentifierSpeechMenu",
        ])
}

extension EPUBContextMenuPolicy {
    /// cooViewer-oxr.35: WebKit が組み立てた menu を identifier だけで絞る。
    /// 許可済み submenu は中身を保ち、識別子のない wrapper は許可された子が
    /// 残る場合だけ保持する。
    @MainActor
    func filter(_ menu: NSMenu) -> Bool {
        switch self {
        case .system:
            return !menu.items.isEmpty
        case .suppressed:
            menu.removeAllItems()
            return false
        case .allowing(let identifiers):
            filter(menu, identifiers: identifiers)
            trimSeparators(in: menu)
            return !menu.items.isEmpty
        }
    }

    @MainActor
    private func filter(_ menu: NSMenu, identifiers: Set<String>) {
        for item in menu.items.reversed() {
            if item.isSeparatorItem { continue }
            if let identifier = item.identifier?.rawValue,
               identifiers.contains(identifier) {
                continue
            }
            if let submenu = item.submenu {
                filter(submenu, identifiers: identifiers)
                trimSeparators(in: submenu)
                if !submenu.items.isEmpty { continue }
            }
            menu.removeItem(item)
        }
    }

    @MainActor
    private func trimSeparators(in menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
