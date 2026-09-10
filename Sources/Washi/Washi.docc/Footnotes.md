# 脚注を表示する / Presenting Footnotes

注への参照を遷移前に捕捉し、内容を抽出して、リーダーの読書位置を
移動させずに表示します。

Intercept note references, extract their content, and present them without
moving the reader.

## 内部リンクを遷移前に捕捉する / Intercept an internal link

出版物内のリンクは、解決されるたびに
``EPUBReaderViewDelegate/readerView(_:shouldFollowInternalLink:)`` に
渡されます。注への参照には `false` を返し、リーダーからその内容を取得します。

Every resolved in-publication link is offered to
``EPUBReaderViewDelegate/readerView(_:shouldFollowInternalLink:)``. Return
`false` for a note reference, then ask the reader for its content:

```swift
import AppKit
import Washi

@MainActor
final class FootnoteCoordinator: EPUBReaderViewDelegate {
    var presentNote: (EPUBNoteContent, CGRect?) -> Void = { _, _ in }

    func readerView(
        _ view: EPUBReaderView,
        shouldFollowInternalLink link: EPUBInternalLink
    ) -> Bool {
        guard link.isNoteReference else { return true }

        Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            if let note = await view.noteContent(for: link) {
                presentNote(note, link.anchorRect)
            } else {
                view.follow(link)
            }
        }
        return false
    }
}
```

リンクの `anchorRect` はリーダービューの座標系で表されるため、AppKit の
ポップオーバーの表示位置を決める錨として使えます。表示中の文書にある注では、
``EPUBNoteContent`` に可読テキストと内部の HTML が含まれます。別の文書にある
注は WebKit を使わずに抽出され、テキストのみが返されます。どちらの場合も、
参照元へ戻るリンクのアンカーは除去されます。

The link's `anchorRect` is expressed in the reader view's coordinate system,
so it can anchor an AppKit popover. For a note in the displayed document,
``EPUBNoteContent`` contains readable text and inner HTML. Cross-document notes
are extracted without WebKit and provide text only. Backlink anchors are
removed in both cases.

``EPUBReaderView/follow(_:)`` は、意図的に delegate のコールバックを経由せず、
現在の locator をナビゲーション履歴に記録します。そのため、リンクを
遷移前に捕捉した後のフォールバックや、ポップオーバーに明示的な「注へ移動」
操作を設ける場合にも、安全に使えます。

``EPUBReaderView/follow(_:)`` deliberately bypasses the delegate callback and
records the current locator in navigation history. It is therefore safe to use
as the fallback after an intercepted link, or when a popover offers an explicit
“Go to note” action.

## 注の aside をページ割りから除外する / Remove note asides from pagination

注を常にページの外で表示する場合は、脚注や後注と認識された aside 要素を
非表示にし、ページ割りの対象から除外します。

If notes are always presented outside the page, hide recognized footnote and
endnote asides from the paginated flow:

```swift
var settings = reader.settings
settings.hidesFootnoteAsides = true
reader.settings = settings
```

この設定はレイアウトに影響します。Washi は現在の項目を再ページ割りします。
設定値は census のメトリクスキーに含まれるため、注を表示した状態での
計測結果が、注を非表示にした状態で再利用されることはありません。

This setting changes layout. Washi repaginates the current item, and the value
is included in the census metrics key so measurements made with visible notes
are not reused for hidden notes.
