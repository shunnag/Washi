# Washi のサンプル / Washi Samples

macOS 14 以降、Swift 6。cooViewer や第三者パッケージは不要。
Xcode 16.4 以降で検証する。`Package.swift` は親の Washi をローカル依存として使い、
Washi 本体からサンプルへの依存はない。公開 API だけを使うため、コードを別アプリへ移せる。

Requires macOS 14+ and Swift 6; tested with Xcode 16.4 and later. No cooViewer or
third-party packages are needed. The samples depend on the parent Washi checkout;
Washi does not depend on these samples. They use only Washi's public API.

## 起動 / Run

```sh
Scripts/run-sample.sh AppKitReader
Scripts/run-sample.sh SwiftUIReader
# ビルドのみ / Build only
Scripts/run-sample.sh SwiftUIReader --build-only
# App Sandbox を有効にして署名・起動 / Sign and launch with App Sandbox
Scripts/run-sample.sh SwiftUIReader --sandbox
```

スクリプトは絶対パスで指定すればリポジトリ外からも実行できる。
`.build/samples/apps/` に `.app` を生成する。サンプルは起動時に同梱の合成本を表示する。
「開く」で EPUB を選び、検索欄で「和紙」を検索して結果を選ぶと移動・ハイライトする。
同じファイルを再度選ぶと読書位置を復元する。保存先は各サンプルの UserDefaults。

The script works from other directories when invoked by absolute path and creates
apps under `.build/samples/apps/`. Each app initially opens the bundled synthetic book.
Choose **Open** to select an EPUB; search for **和紙** in the demo and select a result
to navigate and highlight it. Reopening the same file restores its saved position.
Each sample stores positions in its own UserDefaults.

Sandbox 版の権限は [Sandbox.entitlements](Sandbox.entitlements) にまとめてある。
ユーザー選択ファイルの読み取りと、WKWebView を動作させるための Outgoing Connections
を有効にする。EPUB 本文の外部通信は Washi が引き続き遮断する。

The sandboxed apps use Sandbox.entitlements: user-selected read access and outgoing
connections required by WKWebView. Washi continues to block external requests from EPUB content.

## コードの読み方 / Code map

| ファイル / File | 役割 / Purpose |
|---|---|
| [ReaderSession.swift](Sources/ReaderSampleSupport/ReaderSession.swift) | 非同期読み込み、古い要求の破棄、権限の寿命、delegate、検索、位置保存 / Async loading, stale requests, access lifetime, delegates, search, persistence |
| [ReaderSurface.swift](Sources/ReaderSampleSupport/ReaderSurface.swift) | ビューを保持する SwiftUI ラッパー / SwiftUI adapter retaining the view |
| [AppKitReader.swift](Sources/AppKitReader/AppKitReader.swift) | NSWindow とコントロール / NSWindow and controls |
| [SwiftUIReader.swift](Sources/SwiftUIReader/SwiftUIReader.swift) | StateObject と状態表示 / StateObject and state-driven UI |

ReaderSession / ReaderSurface はサンプル用の型で、Washi のライブラリプロダクトには
含まれない。MIT ライセンスの下でコピー・変更できる。SwiftUI ではウインドウごとに
1 セッションを所有し、`updateNSView` で本を再読み込みしない。破棄時は `close()` を呼ぶ。

ReaderSession and ReaderSurface are sample types, not library products. Copy and adapt
them under the MIT license. Own one session per SwiftUI window; do not reload a book
from `updateNSView`. Call `close()` when discarding the session.

本を閉じると、解析の結果を捨て、検索・位置移動をキャンセルし、`reader.unload()` の後に
ファイル権限を解放する。`EPUBPublication.open` 内の同期解析そのものはキャンセルで
即座に中断されないため、その完了まで当該要求は権限を保持する。

Closing discards an outstanding open result, cancels search/navigation, unloads the
reader, then releases file access. Synchronous parsing inside `EPUBPublication.open`
does not stop immediately on cancellation; that request retains access until it ends.

## 検証 / Verification

```sh
swift test --package-path Samples
```

WebKit を使う描画検証には GUI セッションが必要。サンプルのテストは描画失敗を
スキップしない。ファイル選択・権限の再取得は App Sandbox 版でも手動で確認する。

Rendering tests require a GUI session and do not skip WebKit failures. Also test
file selection and reacquiring file permissions manually with the sandboxed app.
