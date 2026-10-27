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

スクロール表示では同じ仕組みで画面単位の区切りを数える。
連続表示の区間が 4,096 spine 項目を超えると、連続スクロール文書の構成は
章単位スクロールへ縮退するが、`renderingFlow(at:)` は `.scrolledContinuous` を返し続ける。
項目ごとのフロー、この上限、見開きの無効化、進行率と画面番号の関係は <doc:Scrolling> を参照。

Scrolled rendering uses the same pipeline to count screen-sized steps. When a continuous
group exceeds 4,096 spine items, continuous-scroll document construction falls back to
chapter-by-chapter scrolling; `renderingFlow(at:)` still returns `.scrolledContinuous`.
See <doc:Scrolling> for per-item flow, this limit, single-viewport layout, and locator mapping.

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

全文ページ数の実測はオフスクリーン WebKit で数秒かかることがあります。
`exportCensus()` の結果を保存し、再オープン時に `importCensus(_:)` へ渡すと
再実測を省けます。受け付けるのは同じ版かつ現行の `paginationVersion` の
記録だけで、メトリクスも一致していればページ番号とページバーへ即時反映され、
一致しない記録は該当メトリクスが有効になるまで保持されます。

Measuring the whole-book page count with offscreen WebKit can take several
seconds. Persist the result of `exportCensus()` and pass it to
`importCensus(_:)` when reopening to skip remeasurement. Only records for the
same edition and the current `paginationVersion` are accepted; if the metrics
also match, the page number and page bar update immediately, and a record for
other metrics is kept until those metrics become active.

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
呼び出してください。`.utility` などの低い QoS を継いだまま最初の JavaScript
実行を発行すると、WebKit の応答が返らず永久に待ち続けることがあります(実測)。
atlas の census 用とサムネイル用の WebKit インスタンスは、
要求がない状態が 20 秒続くと解放され、次に必要になったときに再作成されます。
それでも、atlas を破棄するときは(キャッシュから追い出すときも含めて)必ず
``EPUBScreenAtlas/invalidate()`` を呼び出してください。無効化すると、処理を
キャンセルし、不可視ウインドウと WebContent プロセスを終了させ、その atlas は
以後使えなくなります。

Call offscreen rendering work from a task with `.userInitiated` priority or
higher. Issuing the first JavaScript execution while inheriting a low QoS such
as `.utility` can leave WebKit unresponsive and wait indefinitely, as observed
in testing. The atlas's census and thumbnail WebKit instances are released
after 20 seconds without a request and recreated lazily. You must still call
``EPUBScreenAtlas/invalidate()`` when discarding an atlas, including when
evicting it from a cache; invalidation cancels work, tears down invisible
windows and WebContent processes, and makes that atlas permanently unusable.

``EPUBPageRasterizer`` は既定では、``EPUBPageRasterizer/invalidate()`` が
呼び出されるまでオフスクリーンリソースを保持します。
``EPUBPageRasterizer/idleReleaseInterval`` を設定すると、最後の描画要求が
終わってからその時間だけアイドル状態が続いた時点で不可視ウインドウと
WebContent プロセスを解放し、次の描画で初回と同じ経路で作り直します。
描画中と FIFO で要求が待っている間には解放せず、設定を変えるとアイドル期限を
予約し直します。0 以下は待機なしの解放を予約します。アイドル解放の後は
再利用でき、``EPUBPageRasterizer/invalidate()`` では恒久的に無効になるので、
どちらの場合も使い終えたら ``EPUBPageRasterizer/invalidate()`` を呼んでください。
リーダービューは、ウインドウから外れると、自身のオフスクリーンの census と
サムネイルの処理をキャンセルし、そのリソースを解放します。

By default ``EPUBPageRasterizer`` keeps its offscreen resources until
``EPUBPageRasterizer/invalidate()`` is called. Setting
``EPUBPageRasterizer/idleReleaseInterval`` releases the invisible window and
the WebContent process once that idle time has elapsed since the last render
request finished, and the next render rebuilds them exactly like a first
render. Nothing is released during a render or while requests wait in the
FIFO, and changing the setting restarts the idle deadline. Nonpositive
intervals schedule an immediate release. Idle release permits reuse, whereas
``EPUBPageRasterizer/invalidate()`` permanently disables the rasterizer, so in
both cases call ``EPUBPageRasterizer/invalidate()`` when you are done. A reader
view cancels and tears down its own offscreen census and thumbnail resources
when it leaves its window.

止めた census は無駄になりません。リーダービューは、測り終えた spine 項目の
ページ数を本とメトリクスキーごとに控え、同じメトリクスで次に実測するときは
最初の未計測項目から続けます(結果は中断なしの実測と同一です)。ウインドウの
ライブリサイズ中は census を始めず、リサイズの終了時に最終的な寸法で一度だけ
予約します。

A stopped census is not wasted. The reader view keeps the page counts of the
spine items it has already measured, per book and metrics key, and the next
census for the same metrics continues from the first unmeasured item (the
result is identical to an uninterrupted census). During a live window resize
no census is started; one is scheduled for the final size when the resize
ends.

## 省エネ方針を選ぶ / Opt into energy pacing

``EPUBReaderView/offscreenEnergyPolicy`` と ``EPUBScreenAtlas/offscreenEnergyPolicy`` は、
census と画面サムネイル(FXL ラスタライズへの委譲も含む)の開始時刻を制御します。
既定値は ``EPUBOffscreenEnergyPolicy/unrestricted`` であり、システム状態の参照や
追加の待機・開始延期を行いません。既存ホストの処理の順序・通知・リソース寿命は変わりません。

``EPUBReaderView/offscreenEnergyPolicy`` and ``EPUBScreenAtlas/offscreenEnergyPolicy``
control pacing for the census and screen thumbnails, including delegated FXL
rasterization. Both default to ``EPUBOffscreenEnergyPolicy/unrestricted``: no
system-state reads, additional waits, or start deferrals. Existing hosts retain
their work ordering, notifications, and resource lifetime.

``EPUBOffscreenEnergyPolicy/followSystem`` を選ぶと、低電力モードが有効か、熱状態が
`serious` / `critical` の間、census が WebKit で読み込む spine 項目とサムネイルのジョブの
開始前にそれぞれ 50 ms 待機します(固定レイアウトや欠損の項目は読み込まないので待機しません)。
100 項目でも追加は 5 秒に収まる小さな間隔で CPU を休ませます(消費電力の低減量を
保証するものではありません)。未開始の census は熱状態が `critical` の間 1 秒ごとに
状態を再確認し、critical を脱するか方針が戻るまで開始を延期します。進行中の census は
項目ごとの待機だけを追加し、途中結果の再開も未計測項目から同じように行います。
方針の変更は以後の項目・ジョブと開始再確認に反映され、現在の項目の計算を中断しません。
キャンセルと無効化は延期中にも適用されます。

With ``EPUBOffscreenEnergyPolicy/followSystem``, Low Power Mode or a `serious` /
`critical` thermal state adds a 50 ms wait before each spine item loaded in
WebKit by the census and before each thumbnail job (fixed-layout and missing
items load nothing and are not paused). This small interval adds only five
seconds for 100 items while giving the CPU a break; it does not guarantee a
measured energy saving. A census that has not started rechecks a `critical`
thermal state every second and defers its start until the state improves or
the policy changes. A running census only adds per-item waits; resumed
measurements pace only their unmeasured items. Policy changes apply to
subsequent items, jobs, and start rechecks, without interrupting computation of
the current item. Cancellation and invalidation also apply during deferral.

待機は常に `.userInitiated` の処理内で行い、WebKit を駆動する QoS は下げません。
方針が変えるのは開始時刻だけです。ページ数、描画寸法、メトリクスの `cacheKey` と
`paginationVersion`(5)、census レコードの互換性は変わりません。

Waits stay inside `.userInitiated` work; the QoS driving WebKit is never lowered.
The policy changes only when work starts. Page counts, render dimensions,
metrics `cacheKey` and `paginationVersion` (5), and census-record compatibility
remain unchanged.
