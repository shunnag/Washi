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
