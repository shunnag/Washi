import AppKit

/// リーダービューのイベント通知の受け取り先。
///
/// Receiver of the reader view's event notifications.
@MainActor
public protocol EPUBReaderViewDelegate: AnyObject {
    /// 表示位置が変わった(ページめくり、章の移動、または位置の復元)。
    ///
    /// The displayed position changed (page turn, chapter move, or restore).
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int)
    /// 本の先頭または末尾を越えて移動しようとした(forward = true は末尾側)。
    ///
    /// An attempt to move past the start/end of the book (forward = true is
    /// the end side).
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool)
    /// 外部リンクを開く直前の通知。既定の動作(ブラウザで開く)を使う場合は
    /// true を返す。
    ///
    /// About to open an external link. Return true for the default action
    /// (open in the browser).
    func readerView(_ view: EPUBReaderView, shouldOpenExternalURL url: URL) -> Bool
    /// 解決済みの EPUB 内部リンクに、リーダーの既定の移動処理を使うかを尋ねる。
    /// 注を表示したりホスト自身で処理したりする場合は false を返す。
    ///
    /// Asks whether a resolved internal EPUB link should use the reader's
    /// default navigation. Return false to show a note or handle it yourself.
    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool
    /// handlesKeyboardNavigation が false のときに使う、キーの転送。
    ///
    /// Key forwarding, used when handlesKeyboardNavigation is false.
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent)
    /// `didReceiveKey` へ渡した直後のキーを、リーダービューで消費するか尋ねる。
    /// false を返すと元のイベントがレスポンダーチェーンを上へ伝わり、ホストが
    /// 処理しないキー(`-`、Esc、`+` など)もウインドウやメニューバーに届く。
    /// 既定は true で、Washi 1.16.x 以前と同じく、キーはここで止まる。
    ///
    /// Asks whether the key just delivered to `didReceiveKey` stops at the
    /// reader view. Return false to let the original event continue up the
    /// responder chain, so keys the host does not handle (`-`, Esc, `+`, …)
    /// still reach the window and the menu bar. Default: true, which keeps the
    /// behaviour of Washi 1.16.x and earlier (the key stops here).
    ///
    /// 同じキーの `didReceiveKey` の直後に呼ぶため、ホストはそこで処理したかを
    /// 記録し、その結果を返すだけでよい。`didReceiveKey` でフラグを設定し、
    /// このメソッドでその値を返す。
    ///
    /// Called right after `didReceiveKey` for the same key, so a host can
    /// record what it handled there and simply report it back:
    /// `didReceiveKey` sets a flag, this method returns it.
    ///
    /// リーダービュー自身が受け取ったキーだけが対象。Web ビューがファースト
    /// レスポンダーの間に入力されたキーをページが処理しなかった場合、
    /// WebKit がレスポンダーチェーンへ再送するため、このメソッドの戻り値に
    /// 関係なく伝播する。
    ///
    /// Only consulted for keys the reader view itself receives. Keys typed
    /// while the web view holds first responder are resent to the responder
    /// chain by WebKit when the page leaves them unhandled, so they propagate
    /// regardless of what this method returns.
    func readerView(_ view: EPUBReaderView,
                    shouldConsumeKey event: EPUBKeyEvent) -> Bool
    /// `EPUBReaderSettings.forwardsKeyEventsNatively` が true の場合だけ届く、
    /// ネイティブのキー押下イベント。true を返すとイベントを消費し、
    /// Web ビューには届かない。false を返すと通常どおり伝播する。
    /// 実際の `NSEvent` が順序どおりに届き、Web ビューがファーストレスポンダー
    /// でも受け取れるため、独自のキーバインドを持つホストには `didReceiveKey`
    /// よりこちらが適している。
    /// 同じウインドウ内の別のコントロールへのイベントは捕捉しない。未処理の
    /// イベントを WebKit が再送しても、このメソッドは再度呼ばれない。
    ///
    /// A native key-down event, delivered only when
    /// `EPUBReaderSettings.forwardsKeyEventsNatively` is true. Return true to
    /// consume the event (the web view never sees it); return false to let it
    /// propagate normally. Preferred over `didReceiveKey` for hosts with their
    /// own key bindings — it is a real `NSEvent`, in order, and reaches you even
    /// while the web view holds first responder.
    /// Events for other controls in the same window are not intercepted, and
    /// WebKit's resend of an unhandled event does not call this method again.
    ///
    /// モニターはレスポンダーチェーンより先に動くため、true を返すとその
    /// イベントによるメニューのショートカット(⌘C、⌘W など)も抑止する。
    /// ホストが実際に処理するキーだけ true を返し、それ以外は false を返す。
    ///
    /// The monitor runs before the responder chain, so returning true also
    /// suppresses menu key equivalents (⌘C, ⌘W, …) for that event. Return true
    /// only for keys your host actually handles; return false for the rest.
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool
    /// リンク以外のページ面でのクリック(左・中央・サイドボタン。
    /// 修飾キーの情報も含む)。
    /// 処理した場合は true、既定の動作を使う場合は false を返す。既定の動作は、
    /// 修飾キーなしの左クリックによる、左右の端タップでのページめくりだけ。
    ///
    /// A click on the page surface (non-link: left/middle/side buttons, with
    /// modifier keys). Return true if handled; false for the default action
    /// (only the left/right edge-tap page turn on an unmodified left click).
    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool
    /// 正規化済み本文の選択範囲が変わった。
    ///
    /// The normalized text selection changed.
    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?)
    /// 方針に従って絞り込んだコンテキストメニューを、ホストが最後に
    /// カスタマイズする。コンテキストメニューのイベントごとに必ず 1 回呼ばれる。
    /// 絞り込み後のメニューが空の場合や、方針が
    /// ``EPUBContextMenuPolicy/suppressed`` の場合も同様。
    /// `nil` または空のメニューを返すと表示を抑止する。空でないメニューを
    /// 返せば、``EPUBContextMenuPolicy/suppressed`` でも表示する。
    ///
    /// Gives the host a final opportunity to customize a policy-filtered context
    /// menu. This method is called exactly once for every context-menu event,
    /// including when the filtered menu is empty and when the policy is
    /// ``EPUBContextMenuPolicy/suppressed``. Return `nil` or an empty menu to
    /// suppress presentation. A non-empty returned menu is presented even under
    /// ``EPUBContextMenuPolicy/suppressed``.
    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu?
    /// ファイルのドロップ(ホストが「別の本を開く」などに使える)。
    /// ドロップを拒否する場合は false を返す。
    ///
    /// A file drop (which the host can use to "open another book", etc.).
    /// Return false to reject the drop.
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool
    /// ピンチ操作などでフォント倍率が変わった(ホストでの保存に使う)。
    ///
    /// The font multiplier changed via pinch, etc. (for the host to persist).
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double)
    /// ページめくり効果を、ページカールなどホスト独自の効果に差し替える。
    /// oldPage/newPage は、ビューの座標系での pageRect に当たるページ領域の
    /// スナップショット。**このメソッド内で同期的に**ビューへオーバーレイを
    /// 追加し、true を返す(Washi はこのメソッドが戻るとすぐに古いページの
    /// カバーを外す)。
    /// 組み込みの pageTurnStyle(slide/fade)を使う場合は false を返す。
    ///
    /// Replace the page-turn effect with a host-specific one (page curl,
    /// etc.). oldPage/newPage are snapshots of the page area (pageRect, in the
    /// view's coordinate system). Add the overlay to the view **synchronously
    /// within this method** and return true (Washi removes the old page's
    /// cover as soon as this returns). Return false to use the built-in
    /// pageTurnStyle (slide/fade).
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool
    /// 読み込みの失敗などのエラー。
    /// 表示できない項目への移動は拒否し、移動前のページに留まり、`currentLocator` も
    /// その位置を返す。別の読み込み中に拒否した場合、その読み込みは続き、
    /// `currentLocator` は進行中の行き先を返し、後で `didMoveTo` が届く。
    /// WebKit が項目の読み込みに失敗した場合(読み込みを開始できなかった場合を含む)は、
    /// 表示準備を終えた文書で最後に表示していた位置(続けて移動した場合は
    /// 最初の移動の前の位置)を読み込み直す。
    /// 通知時の `currentLocator` はその復旧先を返し、復旧後に `didMoveTo` が届く。
    /// 復旧先が無い場合(本を開いた直後など)は失敗した項目の位置を返す。
    /// 失敗ごとに一度通知し、読み込み直しも失敗した場合はもう一度通知して止める。
    /// 読み込んだ文書の表示準備に失敗した場合は読み込み直さず、その項目に留まる
    /// (`currentLocator` はその項目の位置を返す)。この場合は `didMoveTo` は届かない。
    /// ページめくりでは表示できない項目を通知せず飛ばし、残りがすべて表示不能なら
    /// `didReachBookEdge` が届く。スクロール連続表示のグループ内の表示できない項目は
    /// 飛ばさず、グループの表示準備や項目の読み込みの失敗としてこの通知が届く
    /// (この場合は読み込み直さない)。
    /// 読み上げで表示できない章へ進もうとすると、失敗通知の後に再生を終了し、
    /// `isPlayingMediaOverlayDidChange(false)`、`readerViewMediaOverlayDidFinish` の順に届く。
    /// 読み上げが次の章へ進む読み込みに失敗して前の位置を読み込み直した場合は、
    /// 再生中の区間の終わりまでに再生を終える。
    ///
    /// A load failure or similar error.
    /// Navigation to an unloadable item is rejected, keeping the previous page
    /// and its `currentLocator`. If another load is in progress, it continues,
    /// `currentLocator` returns its destination, and `didMoveTo` follows later.
    /// If WebKit fails to load an item (including when the load could not start),
    /// the location last displayed in the last document that finished setup
    /// (for chained moves, the location before the first move) is reloaded. During this callback,
    /// `currentLocator` returns that recovery destination; `didMoveTo` follows
    /// when it is restored. Without a recovery location (for example, just after
    /// opening a book), it returns the failed item's location. Each failure is
    /// reported once; if recovery also fails, another error is reported and
    /// recovery stops. If setup of the loaded document fails, the reader stays
    /// on that item without reloading (`currentLocator` returns its location),
    /// and no `didMoveTo` follows. Page turns skip unloadable items without this
    /// callback, reporting `didReachBookEdge` if no renderable items remain.
    /// Within a continuous-scroll group, unloadable items are not skipped:
    /// this callback reports a group setup or item load failure without reloading.
    /// When narration tries to enter an unloadable chapter, this callback is followed by
    /// `isPlayingMediaOverlayDidChange(false)` and `readerViewMediaOverlayDidFinish`.
    /// If narration fails to move to the next chapter and the previous location
    /// is reloaded, playback ends by the end of the current clip.
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error)
    /// 本全体のページ数の実測(census)が更新された(完了または無効化)。
    /// view.pageCensus / censusTotalPages / currentGlobalPageRange を参照。
    ///
    /// The whole-book page-count measurement (census) was updated (completed
    /// or invalidated). See view.pageCensus / censusTotalPages /
    /// currentGlobalPageRange.
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView)
    /// メディアオーバーレイ(SMIL)の再生が始まった、または一時停止・停止した。
    /// 再生/一時停止コントロールの状態を同期するために使う。
    ///
    /// Media-overlay (SMIL) playback started or paused/stopped. Use it to keep
    /// a play/pause control in sync.
    func readerView(_ view: EPUBReaderView,
                    isPlayingMediaOverlayDidChange isPlaying: Bool)
    /// メディアオーバーレイの再生が本の末尾に達した
    /// (これ以上再生するものがない)。
    /// 再生を続けられなくなった場合(表示位置が読み上げ中の章を離れた、次の章を
    /// 表示できないなど)にも届く。
    ///
    /// Media-overlay playback reached the end of the book (nothing more to play).
    /// Also sent when playback cannot continue, for example because the displayed
    /// position left the narrated chapter or the next chapter cannot be displayed.
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView)
    /// 移動履歴が利用可能かどうかが変わった。
    /// ``EPUBReaderView/canGoBack`` を参照し、「戻る」コマンドやコントロールを
    /// 更新する。
    ///
    /// Navigation-history availability changed. Read ``EPUBReaderView/canGoBack``
    /// to update a Back command or control.
    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView)
    /// 解決済みの印刷ページのラベルが変わった。
    ///
    /// The resolved print page label changed.
    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?)
}

public extension EPUBReaderViewDelegate {
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {}
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {}
    func readerView(_ view: EPUBReaderView,
                    shouldOpenExternalURL url: URL) -> Bool { true }
    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool { true }
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {}
    func readerView(_ view: EPUBReaderView,
                    shouldConsumeKey event: EPUBKeyEvent) -> Bool { true }
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    didClick event: EPUBClickEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?) {}
    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu? { menu }
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double) {}
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {}
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {}
    func readerView(_ view: EPUBReaderView,
                    isPlayingMediaOverlayDidChange isPlaying: Bool) {}
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView) {}
    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {}
    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?) {}
}
