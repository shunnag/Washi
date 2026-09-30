# Washi(和紙)

macOS ネイティブ技術だけで実装した EPUB 3 ツールキット。
日本語組版(縦組み・ルビ・縦中横・圏点・右綴じ)を第一級でサポートする。

An EPUB 3 toolkit built entirely with macOS-native technologies, with
first-class support for Japanese typography: vertical writing, ruby,
tate-chu-yoko, emphasis marks, and right binding.

## すぐに試す / Quick Start

**macOS 14 以降・Swift 6**。Xcode の **File → Add Package Dependencies…** に
`https://github.com/shunnag/Washi.git` を入力し、**Up to Next Major Version** に
最新の [GitHub Release](https://github.com/shunnag/Washi/releases) の版を指定して
追加する。アプリのターゲットには、表示するなら **Washi**、解析・表紙・検索だけなら
**WashiCore** を選ぶ。通常の SwiftPM 利用で WashiDynamic を選ぶ必要はない。

Requires **macOS 14+ and Swift 6**. In Xcode, choose **File → Add Package Dependencies…**,
enter `https://github.com/shunnag/Washi.git`, and use **Up to Next Major Version** with
the latest [GitHub Release](https://github.com/shunnag/Washi/releases).
Add **Washi** to your app target for rendering, or **WashiCore** for parsing, covers,
and search. Ordinary SwiftPM clients do not need WashiDynamic.

まず動作を見たい場合は、独立したサンプルを起動する。両方とも小さな EPUB を同梱し、
ファイル選択、ページ送り、検索とハイライト、読書位置の保存・復元を試せる。

To try a working app first, run either standalone sample. Both include a small EPUB
and demonstrate file selection, paging, search and highlights, and position restoration.

```sh
git clone https://github.com/shunnag/Washi.git
cd Washi
Scripts/run-sample.sh AppKitReader
# SwiftUI 版 / SwiftUI version
Scripts/run-sample.sh SwiftUIReader
```

- [導入と最初の表示 / Installation and first display](Sources/Washi/Washi.docc/Installation.md)
- [サンプルの構成・実行方法 / Sample apps](Samples/README.md)
- [公開ドキュメント / Online documentation](https://shunnag.github.io/Washi/)

公開ガイドとサンプルは main ブランチに追従し、最新の GitHub Release の公開 API で動作する。
MIT ライセンスで、第三者パッケージには依存しない。

The online guides and samples follow the main branch and use the public API of
the latest GitHub Release. MIT-licensed, with no third-party package dependencies.

## リポジトリ構成 / Repository layout

| パス / Path | 内容 / Contents |
|---|---|
| `Package.swift` | SwiftPM manifest。プロダクト `WashiCore` / `Washi` / `WashiDynamic`(cooViewer 向け dylib、契約はコメント参照) / Manifest; products and the WashiDynamic contract |
| `Sources/WashiCore/` | 解析層(AppKit / WebKit なし)。話題ごとのフォルダ / Parsing layer, one folder per topic |
| `Sources/WashiCore/EPUBError.swift` | 両層で共有する `EPUBError` と `EPUBReadStrategy`(フォルダに属さない唯一のファイル) / Shared error and read-strategy types, the only root-level file |
| `Sources/WashiCore/Container/` | ZIP・OCF コンテナの読み出しと CRC / ZIP, OCF container, CRC |
| `Sources/WashiCore/Package/` | パッケージ文書(OPF)とメタデータ・アクセシビリティ / Package document and metadata |
| `Sources/WashiCore/Navigation/` | nav 文書と NCX / Navigation document and NCX |
| `Sources/WashiCore/Publication/` | `EPUBPublication`、locator、本文抽出・検索、表紙、固定レイアウト、脚注 / Publication, locators, text, search, covers |
| `Sources/WashiCore/Encryption/` | `encryption.xml`、フォント難読化、DRM 検出 / Encryption, font deobfuscation, DRM detection |
| `Sources/WashiCore/MediaOverlay/` | SMIL の解析 / SMIL parsing |
| `Sources/WashiCore/Util/` | XML 走査、文字コード判定、メディアタイプ、HTML 実体表(自動生成) / XML, charset, media types, generated HTML entities |
| `Sources/WashiCore/WashiCore.docc/` | WashiCore の DocC カタログ / DocC catalog |
| `Sources/Washi/` | 表示層(AppKit / WebKit)。`WashiExports.swift` が WashiCore を再輸出 / Rendering layer; re-exports WashiCore |
| `Sources/Washi/Reader/` | `EPUBReaderView`、delegate、設定、テーマ CSS、キー処理 / Reader view, delegate, settings |
| `Sources/Washi/WebContent/` | 注入 JavaScript / CSS、scheme handler、スクリプト強化 / Injected scripts, scheme handler |
| `Sources/Washi/Pagination/` | 表示メトリクス、census 記録、フロー判定 / Screen metrics, census records |
| `Sources/Washi/Offscreen/` | 不可視 WebKit による census・サムネイル・ラスタライズ / Offscreen census, thumbnails, rasterizer |
| `Sources/Washi/MediaOverlay/` | メディアオーバーレイ再生 / Media overlay playback |
| `Sources/Washi/Util/` | CSS 色の解析、タイムアウト付き待機 / CSS colors, timeout helpers |
| `Sources/Washi/Washi.docc/` | Washi の DocC カタログとガイド / DocC catalog and guides |
| `Tests/WashiTests/` | 両層の単体テスト(`@testable`)。WebKit を使うものは GUI セッションで実行 / Unit tests for both layers |
| `Tests/WashiPublicAPITests/` | 公開 API だけを使うテスト / Public-API-only tests |
| `Tests/Scripts/` | `Scripts/` の Python テスト(`unittest`) / Python tests for the scripts |
| `Tests/Corpus/` | 公開 EPUB コーパスの manifest と手順(英語) / Public corpus manifest and instructions |
| `Samples/` | 独立した AppKit / SwiftUI サンプルアプリ / Standalone sample apps |
| `Scripts/run-sample.sh` | サンプルのビルドと起動 / Build and launch a sample |
| `Scripts/build-documentation.py` | DocC のビルド、ガイドと README の Swift 例の型検査、静的サイト生成 / DocC build, example typecheck, site |
| `Scripts/fetch-epub-corpus.py` | 公開コーパスの取得と照合 / Fetch and verify the corpus |
| `Scripts/generate-html-entities.py` | WHATWG entities.json から `HTMLEntities.swift` を生成 / Generate the entity table |
| `Scripts/release.sh` | リリース前検証の入口(`release.py` を呼ぶだけ、タグ作成は行わない) / Release preflight entry point |
| `Scripts/release.py` | リリース前検証の本体 / Release preflight checks |
| `Scripts/release_support.py` | 版番号と CHANGELOG 検証の共通部 / Shared version and changelog checks |
| `Scripts/publish-github-release.py` | CI がタグから GitHub Release を作る / CI release publisher |
| `Documentation/` | 監査記録などの開発文書 / Development documents such as audit records |
| `CHANGELOG.md` | 変更履歴(Keep a Changelog) / Change log |
| `.beads/` | 課題管理(beads)。[.beads/README.md](.beads/README.md) 参照 / Issue tracking |

## 特徴 / Features

- **依存ゼロ**: ZIP 読み取り(zip64・CRC 検証)から自前実装。解析層は Foundation の
  `XMLDocument`・CoreFoundation・Compression・CryptoKit・CoreGraphics・ImageIO のみ
  (ヘッドレス利用可)、表示層(`EPUBReaderView` 等)は AppKit・WebKit を使用

  **Zero dependencies**: implemented in-house, starting with ZIP reading (zip64,
  CRC validation). The parsing layer uses only Foundation's `XMLDocument`,
  CoreFoundation, Compression, CryptoKit, CoreGraphics, and ImageIO (headless);
  the rendering layer (`EPUBReaderView` and related types) uses AppKit and WebKit.

- **攻撃的 EPUB への耐性**: zip 爆弾(比率+絶対上限)、XML 実体爆弾(billion laughs。
  互換シムは許容)、異常な深さの XML、パス走査・シンボリックリンク脱出を入口で遮断(テスト付き)

  **Resilience against malicious EPUBs**: blocks zip bombs (ratio and absolute
  limits), XML entity bombs (billion laughs, allowing compatibility shims),
  excessively deep XML, path traversal, and symlink escapes at the point of entry, with tests.

- **EPUB 3.3 の RS(閲覧システム)要件に準拠する設計**(EPUB 2.0.1 後方互換込み):
  OCF コンテナ(複数 rootfile・`mimetype` 検証・`encryption.xml`、`.epub` と展開済み
  フォルダの両方)。パッケージ文書は DCMES + `refines`、`display-seq`、シリーズ
  (`belongs-to-collection`)、`prefix` 正規化、rendition プロパティ、
  `page-progression-direction`、循環ガード付き manifest フォールバック、EPUB 2 の
  `opf:*` 属性と `meta name="cover"`。ナビゲーションは EPUB 3 nav(toc / page-list /
  landmarks)+ NCX フォールバック

  **Designed to conform to EPUB 3.3 reading-system requirements**, with EPUB 2.0.1
  compatibility: OCF containers (multiple rootfiles, `mimetype` validation,
  `encryption.xml`; both `.epub` files and unpacked directories); package documents
  with DCMES + `refines`, `display-seq`, series (`belongs-to-collection`), `prefix`
  normalization, rendition properties, `page-progression-direction`, manifest
  fallback chains with cycle guards, and EPUB 2 `opf:*` attributes and
  `meta name="cover"`; EPUB 3 nav (toc / page-list / landmarks) with an NCX fallback.

- **本文抽出・全文検索**(WebKit 不要): 大小文字・ダイアクリティカルマーク・全半角の
  区別を `EPUBSearchOptions` で個別指定。`EPUBSearchHit.utf16Range` は DOM Range と同じ
  UTF-16 コード単位。XML 宣言と HTML の meta charset を解析・表示で共通判定し、
  Shift_JIS 系は NEC / IBM 拡張を含む CP932、EUC-JP は日本語 EUC として復号

  **Text extraction and full-text search** without WebKit. Configure case, diacritic,
  and character-width sensitivity with `EPUBSearchOptions`; `EPUBSearchHit.utf16Range`
  uses UTF-16 code units like DOM Range. Parsing and rendering share encoding detection;
  Shift_JIS variants decode as CP932 (NEC / IBM extensions), EUC-JP as Japanese EUC.

- **フォント難読化の透過解除**(IDPF / Adobe)。DRM(ADEPT / LCP / FairPlay)は指紋検出して
  明示的に報告(復号はしない)

  **Transparent font deobfuscation** (IDPF / Adobe). DRM (ADEPT / LCP / FairPlay) is
  detected by its signatures and reported explicitly; it is not decrypted.

- **メディアオーバーレイ(SMIL)の再生**: `playMediaOverlay()` / `pauseMediaOverlay()` /
  `stopMediaOverlay()`。読み上げ箇所に `media:active-class` を付け、必要なページへ自動追従

  **Media overlay (SMIL) playback** with `playMediaOverlay()` / `pauseMediaOverlay()` /
  `stopMediaOverlay()`; the narrated passage gets `media:active-class` and the reader
  follows it to the right page.

- **リフローレンダラー** `EPUBReaderView`(AppKit / WKWebView):
  標準 CSS multicol によるページ分割。縦組みは「縦積みカラム + 無アニメーションジャンプ」
  方式(Bibi / Readium CSS と同じモデル。行が途中で割れない)。ウインドウ幅で単ページ⇔
  見開きを自動切替(`columnMode` で固定も可)、縦書きの見開きは半幅ページボックスで右綴じの
  正順、中央にノドと下部中央のノンブル(`showsPageFurniture`)、画像単独ページは中央フィット。
  ライト/ダークテーマ(`EPUBReaderTheme`、`color-scheme` 注入、`invertsGlyphImagesInDark`
  による外字画像の反転)。電書連(DPFJ)EPUB 3 制作ガイド ver.1.1.4 の抽象フォント名
  (`serif-ja` 等)をヒラギノへ結ぶ `@font-face` ポリフィル。
  `WKURLSchemeHandler` によるコンテナ内配信(MIME / CSP / Range)、外部ネットワーク遮断、
  本の JavaScript は既定で無効(有効化時も WebRTC コンストラクタを使用不能にする)

  **Reflowable renderer** `EPUBReaderView` (AppKit / WKWebView): pagination with standard
  CSS multicol; vertical writing uses stacked columns and non-animated jumps (the Bibi /
  Readium CSS model, no split lines). Single page or two-page spread switches with window
  width (`columnMode` fixes it); vertical spreads use half-width page boxes in right-bound
  order with a center gutter and a folio at the bottom (`showsPageFurniture`); single-image
  pages stay centered. Light and dark themes (`EPUBReaderTheme`, injected `color-scheme`,
  `invertsGlyphImagesInDark` for glyph images). An `@font-face` polyfill maps the DPFJ
  EPUB 3 guide (ver. 1.1.4) abstract font names such as `serif-ja` to Hiragino.
  Container resources are served through `WKURLSchemeHandler` (MIME / CSP / Range);
  external network access is blocked; book JavaScript is off by default and, when
  enabled, WebRTC constructors are disabled.

- **設定・位置・履歴**: `EPUBReaderSettings` でフォント倍率・行間・横組み字間・段落間隔・
  著者フォント上書き・ルビ表示・配色・余白・ユーザー CSS。`EPUBLocator`(spine index +
  進行率)で位置を保存/復元。`effectiveReadingDirection` は `page-progression-direction`、
  `primary-writing-mode`、冒頭の XHTML / CSS、RTL 言語の順で決定。`canGoBack` / `goBack()`
  はジャンプ元を最大 50 件保持し、履歴の変化を delegate へ通知

  **Settings, positions, history**: `EPUBReaderSettings` covers font scale, line height,
  horizontal letter spacing, paragraph spacing, font overrides, ruby visibility, colors,
  insets, and user CSS. `EPUBLocator` (spine index + progression) saves and restores
  positions. `effectiveReadingDirection` is derived from `page-progression-direction`,
  `primary-writing-mode`, initial XHTML / CSS, then RTL language. `canGoBack` / `goBack()`
  keep up to 50 jump origins and notify the delegate when history availability changes.

- **リンク・脚注・選択・page-list**: `EPUBInternalLink` と `shouldFollowInternalLink` で遷移前に
  判定し、脚注は `noteContent(for:)` で抽出、`hidesFootnoteAsides` でページ割りから除外、
  `follow(_:)` で delegate を通さず遷移。選択 API(`currentSelection` / `clearSelection()` /
  `rects(forTextRange:inSpineIndex:)`)は正規化 UTF-16 範囲と reader-view 座標を結ぶ。
  EPUB page-list(`printPageLabels` / `go(toPrintPage:)` / `currentPrintPage`)は本文の
  pagebreak marker とノンブルにも連動

  **Links, footnotes, selection, page-list**: inspect links before navigation with
  `EPUBInternalLink` and `shouldFollowInternalLink`; extract notes with `noteContent(for:)`,
  exclude asides with `hidesFootnoteAsides`, and navigate without the delegate via
  `follow(_:)`. Selection APIs (`currentSelection` / `clearSelection()` /
  `rects(forTextRange:inSpineIndex:)`) map normalized UTF-16 ranges to view coordinates.
  EPUB page-list support (`printPageLabels` / `go(toPrintPage:)` / `currentPrintPage`)
  integrates with pagebreak markers and the folio.

- **アクセシビリティと census**: VoiceOver への確定ページ通知と accessibility label/value、
  システムのコントラスト増加・色以外での区別へ追従。全文ページ数の census は、欠落や決定的に
  読めない spine 項目を 1 ページとして計測を続け、部分的な結果も利用可能

  **Accessibility and census**: announces settled pages to VoiceOver, provides labels and
  values, and follows Increase Contrast and Differentiate Without Color. The whole-book
  census counts a missing or deterministically unloadable spine item as one page and
  keeps measuring, so partial results stay usable.

- **ピンチでフォント倍率**(0.5〜3.0 倍): ジェスチャ中は `WKWebView.magnification` で追従し、
  指を離すと進行率を保って再ページ割り。`adjustFontScale(by:)` で段階調整、変更は delegate へ通知

  **Pinch to adjust font scale** (0.5–3.0×): `WKWebView.magnification` follows the gesture;
  on release the content repaginates preserving progression. `adjustFontScale(by:)` steps
  the scale; changes are reported to the delegate.

- **ホスト統合**: キー/クリック/ファイルドロップの delegate 転送、`EPUBContextMenuPolicy` と
  表示直前 delegate によるコンテキストメニュー制御、既定では左右端タップでページ送り。
  `forwardsKeyEventsNatively` でネイティブ `NSEvent` を横取り転送でき、WKWebView にキーを
  食われない(ホスト独自バインドの推奨経路)

  **Host integration**: forwards key, click, and file-drop events to delegates; controls
  context menus with `EPUBContextMenuPolicy` and a pre-presentation delegate; tapping the
  left or right edge turns pages by default. `forwardsKeyEventsNatively` intercepts native
  `NSEvent` keys so WKWebView cannot consume them (the recommended path for host bindings).

- **固定レイアウト**: viewport 解析、`page-spread-left/right/center`、「画像 1 枚だけのページ」の
  検出(WebKit を介さず画像を直接取り出せる。日本の漫画 EPUB の大多数がこの形)、複雑ページの
  オフスクリーンラスタライズ(`EPUBPageRasterizer`)。`device-width` / `device-height` の
  viewport はライブ表示に追従し、ラスタライズ時は `deviceViewportSize` で寸法を渡す
  (`FixedLayoutPageInfo.viewportIsDeviceSized` で判別)。文書全体と itemref ごとの
  `rendition:spread-*` を文書順に解決し、表示と census の見開き計画へ反映

  **Fixed-layout**: viewport parsing, `page-spread-left/right/center`, single-image page
  detection (extract the image without WebKit; most Japanese manga EPUBs use this form), and
  offscreen rasterization of complex pages (`EPUBPageRasterizer`). A `device-width` /
  `device-height` viewport follows the live display area; pass `deviceViewportSize` when
  rasterizing (`FixedLayoutPageInfo.viewportIsDeviceSized` identifies such pages).
  Per-itemref `rendition:spread-*` is resolved in document order and applied to display
  and to the census spread plan.

## 導入 / Installation

通常利用するプロダクトは 2 つ。**`WashiCore`** は解析層のみで、AppKit / WebKit を引かないので
GUI セッションのない**ヘッドレス利用**(CLI・索引・サーバ・変換ツール)に向く。**`Washi`** は
表示層込みで `WashiCore` を再輸出するため、**`import Washi` だけで両層の公開 API が見える**。
`WashiDynamic` は両ターゲットを 1 本の動的ライブラリにまとめたいホスト(フレームワーク同梱)
向けで、通常の SwiftPM 導入では使わない。Xcode と `Package.swift` それぞれの手順は
[導入と最初の表示](Sources/Washi/Washi.docc/Installation.md) を参照。

Two products cover typical use. **`WashiCore`** is the parsing layer only; it does not
link AppKit / WebKit, so it suits **headless use** without a GUI session (CLI tools,
indexing, servers, converters). **`Washi`** adds the rendering layer and re-exports
`WashiCore`, so **`import Washi` exposes both layers**. `WashiDynamic` bundles both targets
into one dynamic library for hosts assembling a framework; ordinary SwiftPM integration
does not use it. See [Installation](Sources/Washi/Washi.docc/Installation.md) for the
Xcode and `Package.swift` steps.

## 使い方 / Usage

解析は main actor の外で行い、表示は `EPUBReaderView` に読み込む。`at:` に `EPUBLocator` を
渡せば位置を復元できる。

Parse off the main actor, then load the publication into an `EPUBReaderView`. Pass an
`EPUBLocator` to `at:` to restore a position.

```swift
import AppKit
import Washi

@MainActor
func open(_ url: URL, in reader: EPUBReaderView, restoring locator: EPUBLocator? = nil) async throws {
    // 解析(重い処理は detached task で走る) / Parse; heavy work runs in a detached task.
    let publication = try await EPUBPublication.open(url: url)
    // 常に .ltr または .rtl と、その出典 / Always .ltr or .rtl, plus its source.
    print(publication.metadata.mainTitle ?? "",
          publication.effectiveReadingDirection, publication.effectiveReadingDirectionSource)
    for item in publication.navigation.toc { print(item.title) }

    // 表示(AppKit) / Display (AppKit).
    reader.load(publication: publication, at: locator)
    // 読書順で次ページ。turnPageLeft() / turnPageRight() は物理方向
    // Next page in reading order; turnPageLeft() / turnPageRight() are physical directions.
    reader.goForward()
}
```

そのほかの API はガイドを参照する。コード例はすべて CI で型検査される。

See the guides for the remaining APIs. Every code example is typechecked in CI.

- [Washi 入門 / Getting started](Sources/Washi/Washi.docc/GettingStarted.md): AppKit のコントローラー、位置と census の保存・復元 / AppKit controller, saving positions and census
- [脚注 / Footnotes](Sources/Washi/Washi.docc/Footnotes.md): 内部リンクの捕捉と `noteContent(for:)` / Intercepting links and note extraction
- [ページ割り / Pagination](Sources/Washi/Washi.docc/Pagination.md): メトリクス、`exportCensus()` / `importCensus(_:)`、オフスクリーン API の優先度と解放 / Metrics, census records, offscreen rules
- [読み込みと終了 / Loading and lifetime](Sources/Washi/Washi.docc/ReaderLifecycle.md): タスクの所有、`unload()`、キーボード転送、実行環境 / Task ownership, unload, key routing, environment
- [検索・表紙・サムネイル / Search, covers, thumbnails](Sources/Washi/Washi.docc/SearchAndRendering.md): `search`、`coverImage(maxPixelSize:)`、`EPUBScreenAtlas` / Search, covers, atlas
- [スクロール表示 / Scrolling](Sources/Washi/Washi.docc/Scrolling.md)、[SwiftUI](Sources/Washi/Washi.docc/SwiftUIIntegration.md)、[ファイルアクセス / File access](Sources/Washi/Washi.docc/FileAccess.md)
- [WashiCore](Sources/WashiCore/WashiCore.docc/WashiCore.md): ヘッドレスの解析・検索の例 / Headless parsing and search

## 対応状況(EPUB 3.3 RS チェックリスト抜粋) / Support Status (EPUB 3.3 RS Checklist Excerpt)

| 領域 / Area | 状態 / Status(✅ = 対応済み / supported) |
|---|---|
| OCF(ZIP / zip64 / mimetype / container.xml / encryption.xml) | ✅ |
| パッケージ文書(metadata refines / spine / rendition / fallback) | ✅ |
| ナビゲーション(nav の toc / landmarks、NCX フォールバック) | ✅ |
| EPUB page-list(一覧・移動・現在位置・本文 marker) | ✅ |
| パッケージ metadata の `dir` / `xml:lang` | ✅(package / metadata から title・creator・contributor へ継承) |
| 実効読書方向(`page-progression-direction` / `primary-writing-mode` / CSS / 言語) | ✅ |
| 内部リンクと `noteref`(遷移前 delegate・脚注抽出) | ✅ |
| フォント難読化(IDPF / Adobe) | ✅ |
| リフロー描画(縦組み・ルビ・縦中横・圏点・右綴じ) | ✅ |
| 固定レイアウト(viewport / spread 指定 / SVG ラッパー) | ✅ |
| 本文テキスト抽出・全文検索(ルビ除去・大小/全半角無視) | ✅(解析層のみ) |
| メタデータ(著者/シリーズ/アクセシビリティの型付きサーフェス) | ✅ |
| scripted コンテンツ | 任意(既定オフ。CSP / 外部通信ルール / WebRTC 無効化込みで有効化可) |
| メディアオーバーレイ(SMIL) | パース+項目取得(`mediaOverlay`)。1.8.0 から再生・active-class ハイライト・自動ページ追従 |
| DRM(ADEPT / LCP / FairPlay) | 非対応(検出して報告) |
| リフロー見開き(横組み / 縦組み) | ✅ |
| FXL 見開き合成 | 未実装(ホスト側で合成可)/ Not implemented; compose in the host |

## 既知の制限 / Known Limitations

- `text-spacing-trim` と `hanging-punctuation: force-end` は WebKit に未実装のため反映されない。

  `text-spacing-trim` and `hanging-punctuation: force-end` have no effect because WebKit
  does not implement them.

- EPUB 3.4 で outdated とされた機能のうち、`rendition:spread` / `rendition:flow` /
  `rendition:orientation` は legacy hint として保持し、フォント難読化・NCX・OPF 2 の `meta`
  は互換性のため引き続き対応する。`collection` 要素には未対応。

  Among the features marked outdated in EPUB 3.4, `rendition:spread`, `rendition:flow`,
  and `rendition:orientation` are retained as legacy hints. Font obfuscation, NCX, and
  OPF 2 `meta` remain supported. The `collection` element is not supported.

- `scrolled-doc` は章単位、`scrolled-continuous` は連続する章をつないで表示する。`roll` と旧
  `pre-paginated` + `scrolled-continuous` は幅を合わせて隙間なく並べる。スクロール中のページ番号は
  画面サイズに基づく区切りで、印刷ページ番号とは異なる。詳細は
  [スクロール表示](Sources/Washi/Washi.docc/Scrolling.md) を参照。

  `scrolled-doc` scrolls each chapter; `scrolled-continuous` joins consecutive chapters.
  Roll and legacy fixed continuous content fit the viewport width without gaps. Screen
  numbers in these modes describe viewport-sized steps, not printed pages.

- `text/html` 宣言の非準拠 spine は、ヘッドレスの本文抽出・検索では可能な範囲で読むが、表示には
  XHTML 等の対応形式への fallback が必要。表示できない項目の正確な検索位置・選択矩形・
  テキストアンカーは返さない。

  Nonconforming text/html spine items remain available for best-effort headless
  extraction/search, but rendering requires a supported fallback such as XHTML.
  Unrenderable items do not return exact text positions, range rectangles, or text anchors.

- `defersTapsForDoubleClick = true` は、ダブルクリックの単語選択より先にページ送りが起きるのを
  防ぐ代わりに、primary click の通知をシステムのダブルクリック間隔だけ遅らせる(既定は `false`)。
  `invertsGlyphImagesInDark` の外字判定はクラス名と表示寸法に基づくため、小さな挿絵を誤判定する
  ことがある(原色が必要な本では `false`)。WebRTC の無効化は `allowsScriptedContent = true` の
  EPUB コンテンツだけが対象で、ホストアプリや別の WebView への一般的な制御ではない。

  `defersTapsForDoubleClick = true` prevents a page turn before double-click word selection
  but delays primary-click notifications by the system double-click interval (default
  `false`). `invertsGlyphImagesInDark` identifies glyph images by class names and rendered
  dimensions and may misclassify small illustrations (set it to `false` for books that need
  original colors). WebRTC is disabled only in EPUB content with
  `allowsScriptedContent = true`, not for the host app or other WebViews.

## 開発 / Development

- 公開 EPUB コーパス(IDPF サンプルと W3C テスト、251 冊)に対するヘッドレスのスモークテスト。
  出典・ライセンス・照合規則は [Tests/Corpus/README.md](Tests/Corpus/README.md)(英語)を参照。
  `WASHI_CORPUS_DIR` が未設定かディレクトリが無ければスキップされる。

  Headless smoke tests over the public EPUB corpus (IDPF samples and W3C tests, 251 books).
  Provenance, licensing, and verification rules are in
  [Tests/Corpus/README.md](Tests/Corpus/README.md). The tests are skipped when
  `WASHI_CORPUS_DIR` is unset or missing.

  ```sh
  python3 Scripts/fetch-epub-corpus.py
  WASHI_CORPUS_DIR="$PWD/.build/epub-corpus" swift test --filter CorpusSmokeTests
  ```

- `Scripts/` の Python スクリプトはどのカレントディレクトリからでも動き、
  `python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'` で検証する。
  `HTMLEntities.swift` は `Scripts/generate-html-entities.py` で生成し、`--check` で最新か確かめる。

  The Python scripts work from any current directory; verify them with the `unittest`
  command above. `HTMLEntities.swift` is generated by `Scripts/generate-html-entities.py`;
  `--check` verifies the table is current.

- 日本語 EPUB の合成フィクスチャは cooViewer の `Scripts/make-jp-epub-fixtures.py <outdir> [--big]`
  で生成できる(Washi には含まれない)。 / Synthetic Japanese EPUB fixtures come from
  cooViewer's `Scripts/make-jp-epub-fixtures.py` (not included in Washi).

- 2026 年 9 月の堅牢化監査の記録は [Documentation/EPUB-Audit-2026-09.md](Documentation/EPUB-Audit-2026-09.md)
  にある(修正は 1.18.0 で公開済み)。 The September 2026 hardening audit is recorded in
  [Documentation/EPUB-Audit-2026-09.md](Documentation/EPUB-Audit-2026-09.md); its repairs
  shipped in 1.18.0.

## ドキュメント / Documentation

[公開 DocC / Online DocC](https://shunnag.github.io/Washi/) から Washi と WashiCore の両方を
参照できる。main 更新時にガイドのコード例とサンプルを検証して公開する。

Browse both modules in the [online DocC documentation](https://shunnag.github.io/Washi/).
Guides and samples are checked before documentation is published from main.

公開 API の doc コメントと DocC カタログ記事は、日本語を正(ベース)として英語を併記する。
内部コメントは日本語で書く。

Public API doc comments and DocC catalog articles use Japanese as the authoritative base,
with English alongside it. Internal comments are written in Japanese.

Swift Package Index 用の設定(`.spi.yml`)は Washi / WashiCore の両ターゲットを生成対象にする。
/ `.spi.yml` enables Swift Package Index documentation for both targets.

ローカルでは `xcodebuild docbuild -scheme Washi -destination 'platform=macOS'` で DocC を
ビルドできる。ガイドと README の全 Swift コード例の型検査と静的サイトの生成は次のコマンドで
行う(出力先には空のディレクトリを指定)。サンプルの検証は `swift test --package-path Samples`。

Build DocC locally with `xcodebuild docbuild -scheme Washi -destination 'platform=macOS'`.
The command below typechecks every Swift example in the guides and README and generates
the static site (use an empty output directory). Verify the samples with
`swift test --package-path Samples`.

```sh
python3 Scripts/build-documentation.py --output-dir .build/docs-site --derived-data .build/docs-derived
```

## 開発体制 / Project Organization

このリポジトリが Washi の正リポジトリであり、開発もここで行う。Issue / PR はこのリポジトリで
受け付ける。開発課題は beads で管理する(初回は `bd bootstrap --yes`、作業の確認は `bd ready`。
cooViewer から移した課題は旧 ID を維持。詳細は [.beads/README.md](.beads/README.md))。
AI エージェント向けの作業規則は [AGENTS.md](AGENTS.md) にある。

This is Washi's canonical repository, where development takes place and issues and pull
requests are accepted. Tasks are tracked in Beads (`bd bootstrap --yes` on a new checkout,
`bd ready` to find work; issues migrated from cooViewer keep their original IDs; see
[.beads/README.md](.beads/README.md)). Working rules for AI agents are in [AGENTS.md](AGENTS.md).

### 利用側 / Consumers

ソースは macOS 14+ / Swift 6(strict concurrency)で Apple Silicon・Intel の両方に対応する。
[cooViewer](https://github.com/shunnag/cooViewer) はこのパッケージの利用者のひとつで、
`WashiDynamic` から Washi.framework を手組みして同梱する(arm64 のみ)。その前提は
`Package.swift` の WashiDynamic のコメントに記す。

The source supports macOS 14+, Swift 6 with strict concurrency, and both Apple Silicon and
Intel. [cooViewer](https://github.com/shunnag/cooViewer) is one consumer; it assembles
Washi.framework from `WashiDynamic` and bundles it (arm64 only). The assumptions it relies
on are documented in the WashiDynamic comment in `Package.swift`.

## リリース前検証 / Release Preflight

公開予定の版を CHANGELOG に `## [X.Y.Z] - YYYY-MM-DD` と空でない本文で記録し、
`EPUBReadingSystem.version` も同じ版に更新する。変更をコミットしてから次を実行する。
作業ツリー(未追跡ファイルを含む)がクリーンで、公開先の最新確定版タグより新しい版で
あることも検証する。

Record the planned version in CHANGELOG as `## [X.Y.Z] - YYYY-MM-DD` with nonempty
release notes, and set `EPUBReadingSystem.version` to that version. Commit the changes
and run the command below. It also requires a clean working tree, including untracked
files, and a version newer than the latest stable tag on the public remote.

```sh
Scripts/release.sh X.Y.Z
# 公開先を切り替える場合 / Use another remote
Scripts/release.sh X.Y.Z --remote origin
```

このスクリプトは検証のみを行う(Python 3.9 以降と Git が必要)。対象コミットの CI が成功したことを
確認してから、タグの作成・push を別途行う。タグは CI 完了前にも SwiftPM から利用できるため、
タグ作成前の確認が必要になる。タグを push すると、テスト・配布構成ビルド・公開 EPUB コーパス検証が
すべて成功した後、CI(`Scripts/publish-github-release.py`)がそのタグの CHANGELOG から
GitHub Release を自動作成する。確定版タグ(`X.Y.Z` または `vX.Y.Z`)と日付付きの変更履歴が必要。

The script performs validation only (Python 3.9+ and Git required). Create and push the
tag separately, after the target commit's CI has passed; SwiftPM can resolve the tag before
CI finishes, so the pre-tag check matters. After the push, CI
(`Scripts/publish-github-release.py`) creates the GitHub Release from the tagged CHANGELOG
once all tests, release artifact builds, and public corpus checks pass. This requires a
stable tag (`X.Y.Z` or `vX.Y.Z`) and a dated changelog entry.

公開処理だけが失敗した場合は、そのタグの CI で失敗したジョブを再実行する。公開済みの Release は
上書きせず、同じタグの下書きがあると自動公開は止まる(確認して手動公開するか、整理して再実行)。
旧タグを手動で補う場合は、ノートを確認した上で
`gh release create X.Y.Z --verify-tag --notes-file notes.md --latest=false` を使う。自動公開は
公開先の最新確定版タグだけを Latest にし、旧版の再実行による巻き戻りを防ぐ。

If only publication fails, rerun the failed jobs in that tag's CI run. Published Releases
are preserved, and an existing draft stops automatic publication (review and publish it
manually, or resolve it and retry). For historical tags, review the notes and use
`gh release create X.Y.Z --verify-tag --notes-file notes.md --latest=false`. Only the
newest stable remote tag becomes Latest, so retries for older versions cannot move it back.

## ライセンス / License

MIT License(LICENSE を参照)。依存パッケージはない。設計にあたり Readium CSS・Bibi
(いずれも実装は独立)の公開知見を参考にした。

MIT License (see LICENSE). There are no package dependencies. The design draws on publicly
shared findings from Readium CSS and Bibi; Washi's implementation is independent of both.
