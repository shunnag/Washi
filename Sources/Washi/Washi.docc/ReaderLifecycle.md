# 読み込みと終了 / Loading and Lifetime

EPUB の解析と、WebKit による本文表示は別の段階。`open` の成功だけでは画面の準備は
終わらない。``EPUBReaderViewDelegate`` の表示位置通知とエラー通知を受け取る。

Parsing and WebKit rendering are separate stages. Successful `open` does not mean the
page is visible. Observe position and error callbacks on ``EPUBReaderViewDelegate``.

| 段階 / Stage | 操作・通知 / Operation or signal |
|---|---|
| 解析 / Parse | `try await EPUBPublication.open(url:)`。失敗は throw / Failure throws |
| 描画開始 / Start rendering | `reader.load(publication:at:)`。同期的に完了を返す API ではない / Does not await rendering |
| 表示位置確定 / Position settled | `readerView(_:didMoveTo:pageInItem:pageCountInItem:)` |
| 描画失敗 / Rendering failed | `readerView(_:didFailWith:)` |
| 全文ページ数 / Whole-book page count | `readerViewDidUpdatePageCensus` と `censusTotalPages` |
| 終了 / Close | 呼び出し側のタスクをキャンセル後に `reader.unload()` / Cancel host tasks, then unload |

census が nil でも本文は読める。nil には未計測・無効化・中止も含まれるので、常に
「計測中」と決めつけず、UI には「総ページ数は未確定」などと表示する。
計測の更新通知は完了だけでなく無効化でも来る。<doc:Pagination> を参照。

The book can be readable while census is nil. Nil can mean not yet measured,
invalidated, or aborted; show “Total pending” rather than assuming work is active.
Census callbacks also report invalidation, not just completion. See <doc:Pagination>.

## タスクの所有 / Own the tasks

ウインドウごとに open、search、範囲ジャンプのタスクを保持する。新しい要求では
古いタスクをキャンセルし、完了時に要求 ID を照合して古い結果を捨てる。
`Task {}` は main actor を継承するので、同期の `search` をそのまま呼ぶと UI を止め得る。
detached task へ渡し、呼び出し側のキャンセルを `withTaskCancellationHandler` で転送する。

Own open, search, and range-navigation tasks per window. Cancel older requests and
compare request IDs before applying results. `Task {}` inherits the main actor, so
calling synchronous `search` there can block UI. Run it in a detached task and forward
cancellation with `withTaskCancellationHandler`.

`EPUBPublication.open` は内部の detached task で同期解析する。呼び出し側をキャンセル
しても即座に中断する保証はない。結果の破棄と、ファイルアクセス権の保持が必要。
`search` はキャンセル時にそれまでの部分結果を返すため、キャンセルされた結果を
現在の検索結果として表示しない。

`EPUBPublication.open` performs synchronous parsing in its internal detached task;
cancelling its caller does not guarantee immediate interruption. Discard the result
and retain file access until parsing finishes. `search` returns partial results on
cancellation; do not present those as the latest search result.

## リソースの終了 / Release resources

``EPUBReaderView/unload()`` は本を閉じるための明示的な入口。ビューをウインドウから
外すとオフスクリーンの計測・サムネイルも自動解放されるが、ホストのタスクはホストが
取り消す。ホストが直接保持する ``EPUBScreenAtlas`` と ``EPUBPageRasterizer`` は、
使い終わったら `invalidate()` を呼ぶ。<doc:SearchAndRendering> に例がある。

Use ``EPUBReaderView/unload()`` to close a book. Removing the view from its window also
releases its offscreen census and thumbnails, but the host must cancel its own tasks.
Call `invalidate()` on host-owned ``EPUBScreenAtlas`` and ``EPUBPageRasterizer`` instances
when finished. See <doc:SearchAndRendering> for an example.

## キーボード操作 / Keyboard routing

既定のページ送りを使うなら設定は不要。独自のキーバインドでは
`settings.forwardsKeyEventsNatively = true` と `readerView(_:didReceiveNativeKey:)`
を使い、実際に処理したキーだけ true を返す。すべてのキーで true を返すと、
⌘C・⌘W などのメニュー操作も止まる。詳しい契約は ``EPUBReaderViewDelegate`` を参照。

Default paging needs no keyboard configuration. For custom bindings, enable
`settings.forwardsKeyEventsNatively` and implement `readerView(_:didReceiveNativeKey:)`.
Return true only for keys you handle; consuming every key also blocks menu shortcuts
such as ⌘C and ⌘W. See ``EPUBReaderViewDelegate`` for the full contract.
