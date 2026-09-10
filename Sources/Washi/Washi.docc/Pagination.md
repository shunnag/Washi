# ページ割りの仕組み / Understanding Pagination

表示中のリーダー、本全体のページ数、オフスクリーンで生成するサムネイルに、
共通の表示メトリクスを使います。

Use one set of display metrics for the live reader, whole-book page counts, and
offscreen thumbnails.

## 共通のレイアウトモデル / One layout model

``EPUBScreenMetrics`` は、ビューポートと ``EPUBReaderSettings`` から、
コンテンツのサイズ、ページ間隔、見開きにするかどうか、ノド、組版設定、
スクリプト付きコンテンツの状態を導出します。表示中の ``EPUBReaderView`` と
オフスクリーンの census は同じ設定を使います。一方、``EPUBScreenAtlas`` は
計測や描画の前に、出版物の実効的な `rendition:spread` 設定を適用します。

``EPUBScreenMetrics`` derives the content size, page gap, spread decision,
gutter, typography, and scripted-content state from a viewport and
``EPUBReaderSettings``. The visible ``EPUBReaderView`` and the offscreen
census use the same setup, while ``EPUBScreenAtlas`` applies the publication's
effective `rendition:spread` preference before measuring or rendering.

静的プロパティ `EPUBScreenMetrics.paginationVersion` の値は、すべての
メトリクスキーに埋め込まれます。``EPUBReaderView/importCensus(_:)`` は、
古いページ割りエンジンのレコードを拒否します。ホストアプリが独自の
キャッシュインデックスを管理する場合は、ページ割りのバージョンをそこに
含めるか、値が変わったときにインデックス内のエントリを破棄してください。

The static `EPUBScreenMetrics.paginationVersion` value is embedded in every
metrics key. ``EPUBReaderView/importCensus(_:)`` rejects records from an older
pagination engine. If a host maintains a separate cache index, include the
pagination version in that index or discard its entries when the value changes.

## 計測したページ数を永続化する / Persist measured counts

``EPUBCensusRecord`` は、メトリクスキー、読書順に並ぶ各 spine 項目の
ページ数、出版物のリリース識別子を保存します。`exportCensus()` は、
リーダーの delegate が census の更新を通知した後にのみ使ってください。
保存したレコードをデコードし、本を読み込んでから `importCensus(_:)` に
渡します。

``EPUBCensusRecord`` stores a metrics key, a page count for each reading-order
item, and the publication release identifier.
Use `exportCensus()` only after the reader delegate reports a census update,
and feed the decoded record to `importCensus(_:)` after loading the book.

読書順に並ぶリソースに欠落があるか、破損によって確実に読み込めない場合は、
その項目を 1 ページと数えて残りの項目の計測を続けます。キャンセル、
タイムアウト、WebContent プロセスの終了が発生した場合は、不完全な
レコードを返さずに、その計測を中止します。

A deterministic missing or broken reading-order resource contributes one page
and does not prevent the remaining items from being measured. Cancellation,
timeout, or WebContent process termination aborts that measurement instead of
publishing an incomplete record.

## リーダーの外で画面構成を計画する / Plan screens outside the reader

atlas は、コレクション表示やサムネイルブラウザ向けに、リーダーと同じ
項目ごとのページ数を提供します。

An atlas exposes the same per-item page counts for a collection or thumbnail
browser:

```swift
import AppKit
import Washi

@MainActor
func buildPlan(
    for publication: EPUBPublication,
    viewportSize: CGSize,
    settings: EPUBReaderSettings
) async -> (counts: [Int], pagesPerScreen: Int)? {
    let atlas = EPUBScreenAtlas(publication: publication)
    defer { atlas.invalidate() }

    let metrics = EPUBScreenMetrics(
        viewportSize: viewportSize,
        settings: settings
    )
    return await atlas.screenPlan(metrics: metrics)
}
```

オフスクリーン描画は、優先度が `.userInitiated` 以上のタスクから
呼び出してください。atlas の census 用とサムネイル用の WebKit インスタンスは、
要求がない状態が 20 秒続くと解放され、次に必要になったときに再作成されます。
それでも、atlas を破棄するときは必ず ``EPUBScreenAtlas/invalidate()`` を
呼び出してください。無効化すると、処理をキャンセルし、不可視ウインドウと
WebContent プロセスを終了させ、その atlas は以後使えなくなります。

Call offscreen rendering work from a task with `.userInitiated` priority or
higher. The atlas's census and thumbnail WebKit instances are released after
20 seconds without a request and recreated lazily. You must still call
``EPUBScreenAtlas/invalidate()`` when discarding an atlas; invalidation cancels
work, tears down invisible windows and WebContent processes, and makes that
atlas permanently unusable.

``EPUBPageRasterizer`` は、``EPUBPageRasterizer/invalidate()`` が
呼び出されるまでオフスクリーンリソースを保持します。リーダービューは、
ウインドウから外れると、自身のオフスクリーンの census とサムネイルの処理を
キャンセルし、そのリソースを解放します。

``EPUBPageRasterizer`` keeps its offscreen resources until
``EPUBPageRasterizer/invalidate()`` is called. A reader view cancels and tears
down its own offscreen census and thumbnail resources when it leaves its
window.
