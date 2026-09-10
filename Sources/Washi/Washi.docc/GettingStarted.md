# Washi 入門 / Getting Started with Washi

main actor の外で EPUB を開いて ``EPUBReaderView`` に表示し、
読書位置とページ割り census をセッション間で保持します。

Open an EPUB away from the main actor, display it in an ``EPUBReaderView``,
and preserve its reading position and pagination census between sessions.

## 出版物を開いて表示する / Open and display a publication

`EPUBPublication.open(url:readStrategy:)` は、CPU 負荷の高いコンテナと
XML の解析を、優先度が `.userInitiated` の detached task で実行します。
処理が返ったら、main actor 上で出版物をリーダーに読み込みます。

`EPUBPublication.open(url:readStrategy:)` performs the CPU-bound
container and XML parsing in a user-initiated detached task. Once it returns,
load the publication into a reader on the main actor:

```swift
import AppKit
import Washi

@MainActor
final class ReaderViewController: NSViewController, EPUBReaderViewDelegate {
    private let reader = EPUBReaderView(frame: .zero)

    var saveLocator: (EPUBLocator) -> Void = { _ in }
    var saveCensus: (EPUBCensusRecord) -> Void = { _ in }

    override func loadView() {
        reader.autoresizingMask = [.width, .height]
        reader.delegate = self
        view = reader
    }

    func open(
        _ url: URL,
        restoring locator: EPUBLocator? = nil,
        census: EPUBCensusRecord? = nil
    ) async throws {
        let publication = try await EPUBPublication.open(url: url)
        reader.load(publication: publication, at: locator)

        if let census {
            _ = reader.importCensus(census)
        }
    }

    func readerView(
        _ view: EPUBReaderView,
        didMoveTo locator: EPUBLocator,
        pageInItem: Int,
        pageCountInItem: Int
    ) {
        saveLocator(locator)
    }

    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        if let census = view.exportCensus() {
            saveCensus(census)
        }
    }
}
```

`EPUBLocator` は `Codable` に準拠しているため、ホストアプリは delegate で
受け取った値を永続化し、次回開くときに `at` 引数で渡せます。識別子がある
場合、出版物は数値の spine インデックスより先に locator の `idref` を
解決するので、版が変わって読書順が変更されても位置を復元しやすくなります。

`EPUBLocator` is `Codable`, so a host can persist the value received
by the delegate and pass it back through the `at` parameter on the next open.
When an identifier is available, the publication resolves the locator's
`idref` before its numerical spine index, which makes restoration resilient to
reading-order changes between editions.

## ページ割り census を再利用する / Reuse a pagination census

リーダーは、表示中のページと同じレイアウト条件で、読書順に並ぶすべての
spine 項目を計測します。この処理が終わるまで、`pageCensus` と
`censusTotalPages` は `nil` です。delegate が更新を通知した後は、
`exportCensus()` が `Codable` に準拠した ``EPUBCensusRecord`` を返します。

The reader measures every reading-order item using the same layout inputs as
the visible page. Until this work finishes, `pageCensus` and
`censusTotalPages` are `nil`. After the delegate reports an update,
`exportCensus()` returns a Codable ``EPUBCensusRecord``.

`load(publication:at:)` の後に `importCensus(_:)` を呼び出してください。
リーダーが受け付けるのは、同じ出版物の版かつ現在のページ割りエンジンに
対応するレコードだけです。表示メトリクスがすでに一致していれば、
ページ数の集計結果をすぐに利用できます。一致していない場合、受け付けた
レコードは、そのメトリクスが有効になるまでキャッシュに保持されます。

Call `importCensus(_:)` after `load(publication:at:)`. The reader accepts a
record only for the same publication edition and current pagination engine.
If its display metrics already match, the page totals become available
immediately; otherwise the accepted record remains cached until those metrics
become active.

キャッシュの同一性とオフスクリーンリソースの寿命については、
<doc:Pagination> を参照してください。

For details about cache identity and offscreen resource lifetime, see
<doc:Pagination>.
