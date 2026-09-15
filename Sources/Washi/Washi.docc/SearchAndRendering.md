# 検索と画像の取得 / Search and Images

## 検索して該当位置へ移動する / Search and navigate

`EPUBSearchHit.utf16Range` を使ってハイライトと範囲ジャンプを作る。
`characterOffset` と `length` は文字単位なので、UTF-16 範囲と混ぜない。
次の関数のタスクはホストが保持し、別の検索や本への移動、終了時にキャンセルする。
出版物のファイル権限もその間保持する。

Use `EPUBSearchHit.utf16Range` for both highlighting and exact navigation. Do not mix
it with the character-based `characterOffset` and `length`. Own and cancel the task
running this function when a new search/book replaces it or the owner closes. Retain
file access for the duration of the operation.

```swift
import Washi

@MainActor
func findFirst(_ query: String, in reader: EPUBReaderView) async {
    guard let publication = reader.publication else { return }
    let worker = Task.detached(priority: .userInitiated) { publication.search(query) }
    let hits = await withTaskCancellationHandler {
        await worker.value
    } onCancel: {
        worker.cancel()
    }
    guard !Task.isCancelled, reader.publication === publication, let hit = hits.first else { return }
    let locator = publication.locator(forSpineIndex: hit.spineIndex)
    let range = (utf16Offset: hit.utf16Range.lowerBound, utf16Length: hit.utf16Range.count)
    reader.highlights = [EPUBHighlight(
        id: "search", spineIndex: hit.spineIndex, idref: locator.idref,
        utf16Offset: range.utf16Offset, utf16Length: range.utf16Length)]
    let landing = await reader.go(to: locator, textRange: range)
    guard !Task.isCancelled, reader.publication === publication else { return }
    if landing == nil { reader.go(to: locator) }
}
```

この例は検索ハイライトを1件だけ表示する。保存済みの注釈と併用する場合は、アプリ側で
永続用と検索用のハイライトを合成して渡す。FXL や本文抽出と DOM が一致しない文書では
正確な範囲ジャンプができない場合があるため、nil のときは章へ移動している。

This example displays one search highlight. Merge it with saved annotations in the
host if needed. Exact range navigation may be unavailable for fixed-layout content
or documents whose extracted text differs from the DOM; nil falls back to chapter navigation.

## 表紙と画面サムネイルの使い分け / Covers versus screen thumbnails

| 用途 / Use | API | 実行環境 / Environment |
|---|---|---|
| 本棚の表紙 / Library cover | `publication.coverImage(maxPixelSize:)` | WashiCore、WebKit 不要 / No WebKit |
| リフローの特定画面 / Reflow screen | ``EPUBScreenAtlas/thumbnail(spineIndex:pageInItem:metrics:isDark:width:)`` | GUI セッション、main actor / GUI session, main actor |
| 複雑な固定レイアウト / Complex fixed-layout page | ``EPUBPageRasterizer`` | GUI セッション、main actor / GUI session, main actor |

表紙はレイアウトの計測を必要としない。存在しない場合の代替アイコンはホストが用意する。

Covers do not require pagination. Provide a placeholder in the host when no cover is available.

```swift
import CoreGraphics
import WashiCore

func libraryCover(for publication: EPUBPublication) async -> CGImage? {
    await Task.detached(priority: .userInitiated) {
        publication.coverImage(maxPixelSize: 480)
    }.value
}
```

画面サムネイルは、リーダーと同じ viewportSize と settings を渡して生成する。
nil は失敗やキャンセルなどでも返る。空画像と決めつけず、プレースホルダーなどで扱う。

Generate screen thumbnails with the reader's viewportSize and settings. Nil may mean
failure or cancellation; handle it with a placeholder rather than treating it as an empty page.

```swift
import AppKit
import Washi

@MainActor
func firstScreen(for publication: EPUBPublication,
                 size: CGSize, settings: EPUBReaderSettings) async -> CGImage? {
    let work = Task(priority: .userInitiated) {
        let atlas = EPUBScreenAtlas(publication: publication)
        defer { atlas.invalidate() }
        let metrics = EPUBScreenMetrics(viewportSize: size, settings: settings)
        return await atlas.thumbnail(spineIndex: 0, pageInItem: 0, metrics: metrics,
                                     isDark: false, width: 240)
    }
    return await withTaskCancellationHandler {
        await work.value
    } onCancel: {
        work.cancel()
    }
}
```

一覧で多数の画面を描く場合は、同じ本の atlas を再利用し、同時実行数を制限する。
キャッシュから破棄するときに invalidate する。全画面を並べる前の計測は
<doc:Pagination> の screenPlan の例を参照。

For multiple thumbnails, reuse the atlas for a book, limit concurrency, and invalidate
it when evicted from the cache. See <doc:Pagination> for screenPlan before listing screens.
