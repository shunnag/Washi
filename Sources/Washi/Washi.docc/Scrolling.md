# スクロール表示 / Scrolled Reading

``EPUBReaderView`` は、EPUB の宣言に応じて表示方法を選ぶ。
通常どおり出版物を `load(publication:at:)` に渡せばよく、別のビューは不要。

EPUBReaderView selects its presentation from the publication declarations.
Load the publication normally; no separate reader view is required.

| 宣言 / Declaration | 表示 / Presentation |
|---|---|
| `auto` / `paginated` | 従来のページ割りと見開き。 / Dynamic pagination and spreads. |
| `scrolled-doc` | 各章を独立してスクロール。横書きは縦方向、縦書きは本文のブロック方向へ動く。章端で次／前へ進むと隣の章へ移る。 / Independently scrollable chapters along their block flow direction. Next/previous at the edge opens the adjacent chapter. |
| `scrolled-continuous` | 同じ指定の連続する章をつなぎ、境界で両方の章を表示できる。 / Consecutive chapters with this flow share one scroll, including both sides of a chapter boundary. |
| `rendition:layout="roll"` | 固定レイアウトの各項目を表示幅に合わせ、縦に隙間なく並べる。 / Fixed-layout items fit the viewport width and form a gapless vertical roll. |

`rendition:flow-*` の itemref 上書きは出版物全体の指定より優先する。
`roll` は出版物全体に適用し、項目ごとの layout / flow 上書きを無視する。
旧形式の `pre-paginated` + `scrolled-continuous` も幅合わせの roll として扱う。

Itemref flow overrides take precedence over the publication default. A roll applies
to the whole publication and ignores local layout/flow overrides. The legacy
pre-paginated plus scrolled-continuous combination also uses width-fitted roll rendering.

これらの解釈は [EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/#flow)
と、roll を追加した [EPUB Reading Systems 3.4](https://www.w3.org/TR/epub-rs-34/)
に基づく。3.4 は実装時点で Candidate Recommendation Draft。

These interpretations follow EPUB Reading Systems 3.3 and the roll model in EPUB
Reading Systems 3.4, a Candidate Recommendation Draft at the time of implementation.

## 操作と設定 / Input and settings

ホイールとトラックパッドは連続移動になり、ページ境界へ吸着しない。
次／前の操作は約1画面ずつ移動する。スクロール表示では、ページめくり演出と
見開きは適用しない。リフローには単ページ用の余白、roll にはビュー全幅を使う。

Wheel and trackpad input scroll continuously without snapping. Next/previous moves
about one viewport. Scrolled rendering disables page-turn effects and spreads.
Reflowable chapters use the single-page insets; rolls use the full view width.

同一の連続スクロール区間は同じブロック方向で構成する。横書きと縦書き、または
左右逆の縦書きを同じ区間に混在させた本は、エラーを delegate へ通知する。
章ごとの DOM と CSS は別々に保つため、同じ要素 ID や CSS セレクターは干渉しない。

Chapters in one continuous group must share a block flow direction. Incompatible
directions within a group produce a delegate error. Chapters retain separate DOMs
and styles, so repeated element IDs and selectors do not collide.

## 位置と画面番号 / Positions and screen numbers

`currentLocator` はスクロール途中の進行率も保持する。位置通知で保存し、
`load(publication:at:)` または `go(to:)` で復元する。フォントや表示幅を変更した後も
同じ文章へ戻したい場合は `currentLocatorWithTextAnchor()` を使う。

The current locator preserves intermediate scroll positions. Save it from position
callbacks and restore with load or go. Use currentLocatorWithTextAnchor when the
same text should be restored across changes in font or viewport size.

`pageCountInItem`、census、atlas は、項目の長さを画面サイズで区切った数を返す。
連続表示の章末の画面には次の章も入り得る。印刷ページ数や一意の物理ページではない。
画面と locator の相互変換には `censusLocator(forGlobalPage:)` と
`censusGlobalPage(for:)` を使い、ホスト側で `count - 1` の式を決め打ちしない。

Counts in the reader, census, and atlas describe screen-sized steps through each
item. A screen near a continuous chapter boundary may include the next chapter.
Use the reader's census locator conversion methods rather than assuming a fixed
count-minus-one formula in the host.

ページ表示とスクロールが混在する本では、atlas の全体の `pagesPerScreen` だけで
一覧を区切らず、項目ごとの増分を使う。

For mixed paginated and scrolled books, enumerate screens with each item's increment.

```swift
import Washi

@MainActor
func screenAddresses(for book: EPUBPublication,
                     metrics: EPUBScreenMetrics) async -> [(spine: Int, page: Int)] {
    let atlas = EPUBScreenAtlas(publication: book)
    defer { atlas.invalidate() }
    guard let plan = await atlas.screenPlan(metrics: metrics) else { return [] }
    return plan.counts.indices.flatMap { index in
        let step = atlas.pagesPerScreen(forSpineIndex: index, metrics: metrics) ?? 1
        return stride(from: 0, to: plan.counts[index], by: step).map { (index, $0) }
    }
}
```

roll では表示近辺の文書を読み込み、離れた文書のフレームを解放する。
リフローの連続区間は、章の長さを正確に決めるため区間内の文書を読み込む。

Roll rendering loads nearby documents and releases distant frames. Continuous
reflowable groups load their documents to determine chapter lengths accurately.

画面サムネイルには `screenThumbnail` / ``EPUBScreenAtlas`` を使う。
``EPUBPageRasterizer`` は引き続き単一の固定レイアウト文書を画像化する API であり、
roll 全体の連結やスクロール位置の描画には使わない。

Use screenThumbnail or EPUBScreenAtlas for screen images. EPUBPageRasterizer
continues to rasterize an individual fixed-layout document, not a joined roll or
an arbitrary scroll position.

スクロール対応に伴い `EPUBScreenMetrics.paginationVersion` は 5 になる。
以前保存した census は再利用せず、同じ表示条件で実測し直す。

Pagination version 5 invalidates census records from before scrolled rendering.
Measure again using the current display conditions.
