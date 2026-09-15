# SwiftUI への組み込み / SwiftUI Integration

``EPUBReaderView`` は NSView。`NSViewRepresentable` を使って SwiftUI に配置する。
ビューと delegate を保持し、SwiftUI の状態更新のたびに本を読み込み直さないことが重要。

Embed the NSView-based ``EPUBReaderView`` with `NSViewRepresentable`. Retain the view
and its delegate, and avoid reloading the publication on every SwiftUI state update.

## 解析済みの本を表示する / Display a parsed publication

次の例は、解析済みの出版物を受け取り、出版物のインスタンスが変わったときだけ
読み込む。読み込み失敗はクロージャで親へ渡す。設定の更新では読書位置を保つ。

This example loads only when the publication instance changes, reports rendering
errors to its parent, and preserves position when settings change.

```swift
import SwiftUI
import Washi

@MainActor
struct BookReader: NSViewRepresentable {
    let publication: EPUBPublication
    var settings = EPUBReaderSettings()
    var onMove: (EPUBLocator) -> Void = { _ in }
    var onError: (any Error) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EPUBReaderView {
        let view = EPUBReaderView(frame: .zero)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: EPUBReaderView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onError = onError
        if view.settings != settings { view.settings = settings }
        if view.publication !== publication { view.load(publication: publication) }
    }

    static func dismantleNSView(_ view: EPUBReaderView, coordinator: Coordinator) {
        view.delegate = nil
        view.unload()
    }

    @MainActor
    final class Coordinator: EPUBReaderViewDelegate {
        var onMove: (EPUBLocator) -> Void = { _ in }
        var onError: (any Error) -> Void = { _ in }

        func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                        pageInItem: Int, pageCountInItem: Int) { onMove(locator) }
        func readerView(_ view: EPUBReaderView, didFailWith error: any Error) { onError(error) }
    }
}
```

`BookReader(publication: book).frame(minWidth: 400, minHeight: 500)` のように配置する。
親が閉じるときは、進行中の open/search タスクも取り消す。ファイル権限を所有する
オブジェクトは、ビューとそれらの処理が出版物を使い終わるまで保持する。

Place it with `BookReader(publication: book).frame(minWidth: 400, minHeight: 500)`.
Cancel pending open/search tasks when the owner closes. Retain the file-access owner
until the view and all outstanding work finish using the publication.

## ファイル選択・状態管理を含める / Include file selection and state

[サンプルの ReaderSession と ReaderSurface](https://github.com/shunnag/Washi/tree/main/Samples/Sources/ReaderSampleSupport)
には、`@StateObject` での所有、解析中／描画中／読書可能／失敗の状態、検索、
位置保存、古い要求の破棄、終了処理が含まれる。これらはコピーして利用できる
サンプル用の型で、Washi の公開プロダクトには含まれない。

The sample's ReaderSession and ReaderSurface include `@StateObject` ownership,
opening/rendering/ready/failed states, search, persistence, stale-request rejection,
and cleanup. These are reusable sample types, not types shipped in the Washi products.

1 つのリーダービューを複数のウインドウへ同時に置かない。ウインドウごとにセッションを
作る。`EPUBPublication` は `Sendable` なので共有できるが、ビューは `@MainActor` で扱う。

Create one session per window rather than placing the same reader in multiple windows.
`EPUBPublication` is Sendable and can be shared; views remain main-actor isolated.

## セッションを自分のアプリへ移す / Adapt the session to your app

AppKit と SwiftUI の両サンプルは同じ `ReaderSession` を利用している。
ビューの所有と非同期処理の世代管理は共通化できる一方、次の方針はホストアプリで決める。
このため、現時点ではサンプルのセッションをそのまま `WashiSwiftUI` プロダクトへ
追加せず、変更できる実装例として提供する。SwiftUI を使わない既存のアプリは、
引き続き Washi / WashiCore だけを依存先にできる。

Both samples share ReaderSession. View ownership and stale-request rejection are
reusable, but the following policies belong to the host app. The session therefore
remains adaptable sample code rather than a new WashiSwiftUI product. Existing apps
can continue depending on Washi or WashiCore without adopting a SwiftUI session API.

| 項目 / Concern | サンプルの選択と変更点 / Sample policy and adaptation |
|---|---|
| 所有 / Ownership | ウインドウごとに `@StateObject`。同じビューを複数の表示先で共有しない。ドキュメント型アプリではドキュメントとウインドウの寿命を分ける。 / One state object per window; separate document lifetime from window lifetime in document-based apps. |
| ファイル / Files | `NSOpenPanel` と選択 URL。アプリの `fileImporter`、ブックマーク、書庫内データなどに合わせて入口を変更する。アクセス権は解析・描画・検索が完了するまで保持する。 / Adapt the input to fileImporter, bookmarks, or in-memory data; retain access through all outstanding work. |
| 保存 / Persistence | URL をキーに UserDefaults へ位置を保存。改名・移動・複数端末で共有するアプリでは、書籍 ID とアプリの保存層へ置き換える。 / Replace URL-keyed UserDefaults with book identity and your persistence layer when supporting moves or sync. |
| 状態 / State | `opening` は解析、`displaying` は本文の準備、`ready` は位置通知を受けた状態。`totalPages == nil` は総数未確定であり、計測中・失敗・未実施を区別しない。 / Readiness follows a position callback; an unknown total does not distinguish running, failed, or unrequested census work. |
| エラー / Errors | `errorMessage` はサンプル表示用。再試行やログに必要なアプリでは、元のエラーと発生した操作を保持し、表示文言をアプリ側で翻訳する。 / Preserve the original error and operation for retry or logging, and localize messages in the app. |
| 取り消し / Cancellation | `close()` は古い結果を捨て、検索・移動を取り消す。同期解析の即時停止は保証しない。 / Closing rejects stale results and cancels search/navigation; synchronous parsing may finish later. |
| delegate | セッションが所有する。リンク・入力・独自アニメーションを扱う場合は同じ delegate に実装し、別の delegate を代入して状態通知を失わないようにする。 / Add link, input, and animation policies to the session delegate rather than replacing it and losing state updates. |

SwiftUI が同じビューの識別子を保つ間は、`ReaderSurface` に渡すセッションも同じものを
保つ。セッション自体を交換する設計なら `.id(...)` も変更してビューを作り直す。
単にサイドバーを切り替えるだけで破棄・再生成すると `dismantleNSView` が本を閉じるため、
読書を継続したい場合はリーダーの識別子と配置を保つ。

Keep the session stable for the lifetime of a ReaderSurface identity. If replacing
the session itself, change `.id(...)` as well to recreate the native view. Removing
the surface invokes dismantleNSView and closes the book; preserve its identity and
placement when a sidebar change should leave reading uninterrupted.

将来ライブラリ化する場合も、表示と型付き状態・操作の契約を先に分離し、
ファイル選択 UI・保存先・翻訳文言を含めない。複数ウインドウ、セッション交換、
表示の一時取り外し、取り消し後の遅い完了を、通常の `import` だけを使う利用側テストで
検証してから公開 API を固定する。

Any future library adapter should separate presentation and typed state/actions
from file-selection UI, persistence, and translated strings. Its public-import
tests should cover multiple windows, session replacement, temporary detachment,
and late completion after cancellation before that API becomes a stable contract.
