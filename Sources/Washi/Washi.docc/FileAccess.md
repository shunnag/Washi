# ファイルアクセスと保存 / File Access and Persistence

App Sandbox のアプリでは、Signing & Capabilities → App Sandbox の **User Selected File**
を **Read Only** にし、NSOpenPanel または SwiftUI の fileImporter で EPUB を選ぶ。
Washi 自体はファイル選択 UI や security-scoped bookmark の管理を行わない。

For an App Sandbox app, set **User Selected File** to **Read Only** in Signing &
Capabilities, and select an EPUB with NSOpenPanel or SwiftUI's fileImporter.
Washi does not own file-selection UI or security-scoped bookmarks.

表示層で WKWebView を使う場合は、**Outgoing Connections (Client)**
(`com.apple.security.network.client`) も有効にする。この設定がない App Sandbox 版では、
同梱の EPUB でも WebContent プロセスが終了し本文を表示できないことを検証環境で確認した。
これはアプリ側の権限であり、Washi による EPUB 本文の外部通信遮断は継続する。
WashiCore だけでローカルファイルを解析する場合には不要。

When rendering with WKWebView, also enable **Outgoing Connections (Client)**
(`com.apple.security.network.client`). In our sandboxed-app test, omitting it caused
WebContent termination even with the bundled EPUB. This app entitlement does not
disable Washi's blocking of external requests from EPUB content. It is unnecessary
when using only WashiCore to parse local files.

## 遮断の層とホストの責務 / Isolation layers and host responsibilities

Washi は外部通信を単一の仕組みで保証するのではなく、複数の層で抑止する。
全応答に付く Content Security Policy、`washi-epub` 以外の遷移拒否、初回
ナビゲーション前に登録する `WKContentRuleList` を使う。rule list のコンパイル
失敗は error ログに記録し、CSP と遷移拒否を保って描画を続ける。

``EPUBSchemeHandler`` を自前の `WKWebView` に接続するだけでは、CSP 以外の層は
構成されない。通常は ``EPUBReaderView`` を使うこと。独自構成では、遷移拒否、
rule list、隔離された content world、著者スクリプトの硬化もホストが用意する必要がある。

App Sandbox は必須ではないが、信頼できない EPUB を扱うなら有効にすることを推奨する。
表示・画面外の census・サムネイル・ラスタライズは、いずれも本文を WebKit で処理する。
WashiCore の解析と、表紙画像・メディアオーバーレイ音声のデコードはホストのプロセス内で
行われるため、サンドボックスなしで攻撃的な入力を渡してはいけない。

既定の `contextMenuPolicy = .system` では、WebKit の Search Web / Translate / LookUp が
選択本文を外部サービスへ送り、「イメージを別名で保存」が本文をディスクへ書く場合がある。
これらは WebView の要求ではないため CSP・遷移拒否・rule list は適用されない。方針と
delegate で制御すること。`textColorCSS` と `userCSS` にも、信頼できない文字列をそのまま
渡さないこと。

`allowsScriptedContent = true` では著者 JavaScript が DOM イベントを生成できる。
外部 URL・キー・タップは `event.isTrusted` が true の実入力だけを中継するが、選択テキスト
やリンクのメタデータは本の内容として扱い、外部サービスへの送信をホストが判断すること。

既定では本の音声・動画にも利用者の操作を要求する。``EPUBReaderSettings/allowsMediaAutoplay``
で自動再生を許可すると、音声付きの自動再生も有効になるため、信頼できる本にだけ設定すること。

展開済み directory は、検査と open が別々の check-then-open になる。信頼できない
展開済み directory は、変更されうるファイルをそのまま開かず、先に `.epub` へ固めてから開くこと。

## English

Washi combines several isolation layers rather than promising a single unconditional
network boundary: CSP on every response, refusal of navigations outside `washi-epub`,
and a `WKContentRuleList` installed before the first navigation. Rule-list compilation
failures are logged as errors, and rendering continues with CSP and navigation refusal.

Attaching only ``EPUBSchemeHandler`` to a custom `WKWebView` configures just CSP. Use
``EPUBReaderView`` for the complete setup, or provide navigation refusal, the rule list,
the isolated content world, and scripted-content hardening yourself.

App Sandbox is optional but recommended for untrusted books. Onscreen and offscreen
rendering both process book content with WebKit. WashiCore parsing, cover decoding, and
media-overlay audio decoding run in the host process, so hostile input must not be passed
to an unsandboxed host.

The default system context menu can send selected text to external services and save book
images to disk. Those actions do not pass through the web view, so CSP, navigation refusal,
and the rule list cannot stop them. Configure the menu policy and delegate. Do not pass
untrusted strings to `textColorCSS` or `userCSS`.

With scripted content enabled, author JavaScript can synthesize DOM events. Only trusted
input opens external URLs or forwards keys and taps. Treat selection text and link metadata
as book content and apply your own policy before sharing them.

Authored audio and video require user interaction by default. Enabling
``EPUBReaderSettings/allowsMediaAutoplay`` also permits audible autoplay; opt in only for trusted books.

Unpacked directories are inspected and opened in separate steps (check-then-open). Package
an untrusted directory as an `.epub` first instead of opening its mutable files directly.

## アクセス権を出版物と一緒に保持する / Retain access with the publication

解析完了後にも本文・画像・フォントを読み取る。特に展開済み EPUB フォルダでは、
`open` が返った直後にアクセス権を解放すると後続の読み込みが失敗し得る。
次の所有オブジェクトを、リーダー、検索、描画が終わるまで保持する。

Body text, images, and fonts can be read after opening, particularly for unpacked EPUB
folders. Releasing access immediately after `open` may break subsequent reads. Retain
the following owner until the reader, search, and rendering work finish.

```swift
import Foundation
import Washi

final class FileGrant: Sendable {
    private let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

struct OpenedBook: Sendable {
    let publication: EPUBPublication
    private let grant: FileGrant

    static func open(url: URL) async throws -> OpenedBook {
        let grant = FileGrant(url: url)
        let publication = try await EPUBPublication.open(url: url)
        return OpenedBook(publication: publication, grant: grant)
    }
}
```

`startAccessing…` が false でも、アプリ内蔵ファイルなど元からアクセスできる URL は
読める。実際の読み込みエラーを処理する。true を返した呼び出しと stop は対にする。
キャンセルしても `EPUBPublication.open` 内の同期解析は即座に止まらないため、解析の
完了までは権限を保持し、古い結果を UI に戻さない。<doc:ReaderLifecycle> を参照。

A false result from `startAccessing…` does not necessarily mean the file is unreadable:
bundled files may already be accessible. Handle actual read errors, and balance every
successful start with a stop. Cancellation does not immediately interrupt synchronous
parsing inside `EPUBPublication.open`; retain access until it ends and discard stale results.

## 次回起動でファイルを開く / Reopen after relaunch

読書位置の `EPUBLocator` と、ファイルへのアクセス権は別々に保存する。
bookmark を使うアプリには `com.apple.security.files.bookmarks.app-scope` も設定する。

Persist `EPUBLocator` separately from permission to access the file. Apps using
app-scoped bookmarks also need `com.apple.security.files.bookmarks.app-scope`.

```swift
import Foundation

func makeBookBookmark(url: URL) throws -> Data {
    try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                         includingResourceValuesForKeys: nil, relativeTo: nil)
}

func resolveBookBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                      relativeTo: nil, bookmarkDataIsStale: &stale)
    return (url, stale)
}
```

有効なアクセス権がある間に bookmark を作成する。復元した URL は上の OpenedBook などで
アクセスを開始し、isStale が true ならアクセス中に bookmark を作り直す。
解決または読み込みが失敗したら、ファイル選択を再度提示する。
サンプルは同じファイルを選び直したときの位置復元を示し、bookmark の自動再オープンは行わない。

Create bookmarks while access is valid. Start access to resolved URLs with an owner
such as OpenedBook; refresh stale bookmarks while access is active. Ask the user to
select the file again if resolution or reading fails. The samples restore position
when the same file is selected again; they do not automatically reopen bookmarks.

詳細は [Apple の App Sandbox ガイド](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
を参照。iCloud や取り外されるボリューム上のファイルでは、アプリ管理領域へのコピー、
ファイル協調、または `.alwaysCopy` の採用も検討する。`.alwaysCopy` は展開済みフォルダを
一括コピーする設定ではなく、各リソースの読み込み方を指定する。

See Apple's App Sandbox guide. For iCloud or removable storage, consider copying to
app-managed storage, file coordination, or `.alwaysCopy`. For unpacked folders,
`.alwaysCopy` controls individual reads; it does not copy the whole directory upfront.
