# Washi(和紙)

macOS ネイティブ技術だけで実装した EPUB 3 ツールキット。
日本語組版(縦組み・ルビ・縦中横・圏点・右綴じ)を第一級でサポートする。

An EPUB 3 toolkit built entirely with macOS-native technologies, with
first-class support for Japanese typography: vertical writing, ruby,
tate-chu-yoko, emphasis marks, and right binding.

**Washi** は macOS のシステムフレームワークだけで構成した、MIT ライセンスの
EPUB 3 ツールキット。第三者パッケージには依存しない。解析層は Foundation /
CoreFoundation / Compression / CryptoKit / CoreGraphics / ImageIO だけを使うため
ヘッドレスでも動作し、表示層は AppKit / WebKit を加える。縦組み(`vertical-rl`)・
ルビ・縦中横・圏点・右綴じを含む日本語組版を第一級の機能として扱う。

**Washi** is an MIT-licensed EPUB 3 toolkit built solely on macOS system
frameworks, with no third-party package dependencies. Its parsing layer uses
only Foundation / CoreFoundation / Compression / CryptoKit / CoreGraphics /
ImageIO and works headlessly; its rendering layer adds AppKit / WebKit.
Japanese typography is a first-class feature, including vertical writing
(`vertical-rl`), ruby, tate-chu-yoko, emphasis marks, and right binding.

## 特徴 / Features

- **依存ゼロ**: ZIP 読み取り(zip64 対応・CRC 検証)から自前実装。
  解析層は Foundation の `XMLDocument`・CoreFoundation・Compression・CryptoKit・
  CoreGraphics・ImageIO のみ(ヘッドレス利用可)、表示層(`EPUBReaderView` 等)は
  AppKit・WebKit を使用

  **Zero dependencies**: implemented in-house, starting with ZIP reading
  (zip64 support and CRC validation). The parsing layer uses only Foundation's
  `XMLDocument`, CoreFoundation, Compression, CryptoKit, CoreGraphics, and
  ImageIO (suitable for headless use); the rendering layer (`EPUBReaderView`
  and related types) uses AppKit and WebKit.

- **攻撃的 EPUB への耐性**: zip 爆弾(比率+絶対上限)、XML 実体爆弾
  (billion laughs。互換シムは許容)、異常な深さの XML、パス走査・
  シンボリックリンク脱出をすべて入口で遮断(テスト付き)

  **Resilience against malicious EPUBs**: blocks zip bombs (ratio and absolute
  limits), XML entity bombs (billion laughs, while allowing compatibility
  shims), excessively deep XML, path traversal, and symlink escapes at the
  point of entry, with tests.

- **EPUB 3.3 の RS(閲覧システム)要件に準拠する設計**(EPUB 2.0.1 後方互換込み):

  **Designed to conform to EPUB 3.3 reading system (RS) requirements**, with
  backward compatibility for EPUB 2.0.1:

  - OCF コンテナ(`container.xml` 複数 rootfile / `mimetype` 検証 /
    `encryption.xml`)。`.epub` と展開済みフォルダの両方を開ける

    OCF containers (multiple rootfiles in `container.xml`, `mimetype`
    validation, and `encryption.xml`). Opens both `.epub` files and unpacked
    directories.

  - パッケージ文書: DCMES + `refines`、`display-seq`、`belongs-to-collection`
    (シリーズ)、`prefix` 宣言の正規化、rendition プロパティ、
    `page-progression-direction`、manifest フォールバック連鎖(循環ガード付き)、
    EPUB 2 の `opf:*` 属性・`meta name="cover"`

    Package documents: DCMES with `refines`, `display-seq`,
    `belongs-to-collection` (series), normalization of `prefix` declarations,
    rendition properties, `page-progression-direction`, manifest fallback
    chains with cycle guards, and EPUB 2 `opf:*` attributes and
    `meta name="cover"`.

  - ナビゲーション: EPUB 3 nav(toc / page-list / landmarks)+ NCX フォールバック

    Navigation: EPUB 3 nav (toc / page-list / landmarks), with an NCX fallback.

  - **本文抽出・全文検索**: WebKit を使わず、大小文字・ダイアクリティカルマーク・
    全半角の区別を `EPUBSearchOptions` で個別指定できる。
    `EPUBSearchHit.utf16Range` は DOM Range と同じ UTF-16 コード単位

    **Text extraction and full-text search** without WebKit. Configure case,
    diacritic, and character-width sensitivity independently with
    `EPUBSearchOptions`. `EPUBSearchHit.utf16Range` uses UTF-16 code units,
    just like DOM Range.

  - XML 宣言と HTML の meta charset を解析・表示で共通判定し、Shift_JIS 系は
    NEC / IBM 拡張文字を含む CP932、EUC-JP は日本語 EUC として復号

    Parsing and rendering share encoding detection for XML declarations and
    HTML meta charset. Shift_JIS variants are decoded as CP932, including
    NEC / IBM extensions, and EUC-JP is decoded as Japanese EUC.

  - **フォント難読化の透過解除**: IDPF(SHA-1/1040 バイト)と
    Adobe(UUID/1024 バイト)。DRM(ADEPT / LCP / FairPlay)は指紋検出して
    明示的に報告(復号はしない)

    **Transparent font deobfuscation**: IDPF (SHA-1 / 1040 bytes) and Adobe
    (UUID / 1024 bytes). DRM (ADEPT / LCP / FairPlay) is detected by its
    signatures and explicitly reported; it is not decrypted.

  - **メディアオーバーレイ(SMIL)の再生**: `playMediaOverlay()` /
    `pauseMediaOverlay()` / `stopMediaOverlay()` で制御し、読み上げ箇所へ
    `media:active-class` を付けてハイライトしながら必要なページへ自動追従

    **Media overlay (SMIL) playback**: control playback with
    `playMediaOverlay()` / `pauseMediaOverlay()` / `stopMediaOverlay()`.
    The narrated passage is highlighted with `media:active-class`, and the
    reader automatically follows it to the appropriate page.

- **リフローレンダラー** `EPUBReaderView`(AppKit / WKWebView):

  **Reflowable renderer** `EPUBReaderView` (AppKit / WKWebView):

  - 標準 CSS multicol によるページ分割。縦組みは「縦積みカラム + 無アニメーション
    ジャンプ」方式(Bibi / Readium CSS と同じ、実運用で実証済みのモデル。
    行が途中で割れない)

    Pagination with standard CSS multicol. Vertical writing uses vertically
    stacked columns and jumps without animation, the same proven model used
    by Bibi / Readium CSS, keeping lines from splitting midway.

  - **Apple Books 風の版面**: ウインドウ幅で単ページ⇔**見開き 2 ページ**を
    自動切替(`columnMode` で固定も可)。縦書きの見開きは
    `-webkit-column-axis: horizontal` の半幅ページボックス(WKWebView 専用・
    実測検証済み)で右綴じの正順(先のページが右)。中央にノド、
    **各ページの下部中央に素のノンブル**(`showsPageFurniture` で OFF 可)。
    表紙などの画像単独ページは見開き時も単独の中央フィット

    **Apple Books-style page layout**: automatically switches between a
    single page and a **two-page spread** based on window width (or fixes the
    mode with `columnMode`). Vertical spreads use half-width page boxes with
    `-webkit-column-axis: horizontal` (WKWebView-specific and verified by
    measurement), in right-bound reading order with the earlier page on the
    right. A center gutter separates the pages, and a **plain folio (page
    number) is centered at the bottom of each page** (disable with
    `showsPageFurniture`). Single-image pages such as covers remain centered
    and fitted individually, even in spread mode.

  - **ライト/ダークテーマ**: 既定でシステム外観に追従(`EPUBReaderTheme` で
    固定も可)。ダークは Apple Books 系のほぼ黒 + 明灰文字で、
    `color-scheme` も注入する。`invertsGlyphImagesInDark` は小さなインライン
    外字画像をヒューリスティックに反転し、無指定 fill のインライン SVG と
    黒 stroke は `currentColor` で描画する

    **Light and dark themes**: follows the system appearance by default
    (or selects a fixed theme with `EPUBReaderTheme`). The dark theme uses
    near-black backgrounds and light-gray text in the style of Apple Books,
    and injects `color-scheme`. `invertsGlyphImagesInDark` heuristically
    inverts small inline glyph images; inline SVG with unspecified fill and
    black strokes is rendered with `currentColor`.

  - 電書連(DPFJ)EPUB 3 制作ガイド ver.1.1.4(2025-10、旧電書協 1.1.3 と
    CSS 互換)のテンプレートが使う抽象フォント名(`serif-ja` 等)を
    ヒラギノ明朝 ProN / ヒラギノ角ゴシックへ結び付ける `@font-face` ポリフィル

    An `@font-face` polyfill maps abstract font names such as `serif-ja` in
    the DPFJ EPUB 3 production guide templates (ver. 1.1.4, October 2025;
    CSS-compatible with the former EBPAJ 1.1.3 templates) to Hiragino Mincho
    ProN / Hiragino Kaku Gothic.

  - `WKURLSchemeHandler` によるコンテナ内配信(正しい MIME / CSP /
    Range 対応)。外部ネットワークはコンテンツルールで遮断、
    本の JavaScript は既定で無効。有効化した場合も PAGE world の
    document-start script で WebRTC コンストラクタを使用不能にし、
    CSP だけでは遮断できない STUN / UDP 経路を閉じる

    Serves container resources through `WKURLSchemeHandler` with correct
    MIME types, CSP, and Range support. Content rules block external network
    access, and the book's JavaScript is disabled by default. Even when
    enabled, a document-start script in the page world disables WebRTC
    constructors, closing STUN / UDP paths that CSP alone cannot block.

  - `EPUBReaderSettings` でフォント倍率・行間・横組み字間・段落間隔・
    著者フォントの上書き・ルビの表示/非表示、型付き配色・余白・
    ユーザー CSS を指定。`EPUBLocator`(spine index + 進行率)で位置を保存/復元

    `EPUBReaderSettings` configures font scale, line height, horizontal
    letter spacing, paragraph spacing, authored font overrides, ruby
    visibility, typed colors, insets, and user CSS. Save and restore reading
    positions with `EPUBLocator` (spine index + progression).

  - 宣言された `page-progression-direction`、`primary-writing-mode`、冒頭の
    XHTML / CSS、RTL 言語の順で `effectiveReadingDirection` を決め、
    表示層もその実効値を使用

    Determines `effectiveReadingDirection` from the declared page progression
    (`page-progression-direction`), `primary-writing-mode`, initial
    XHTML / CSS, and RTL language, in that order. The rendering layer uses
    this effective direction as well.

  - 内部リンク・目次・locator・UTF-16 範囲へのジャンプ元を最大 50 件保持する
    `canGoBack` / `goBack()` と、履歴の利用可否が変わったときの delegate 通知

    `canGoBack` / `goBack()` retain up to 50 source positions for jumps via
    internal links, the table of contents, locators, and UTF-16 ranges, with
    delegate notifications when navigation history availability changes.

  - `EPUBInternalLink` と `shouldFollowInternalLink` delegate で内部リンクを
    遷移前に判定。同一文書／別文書の脚注は `noteContent(for:)` で抽出でき、
    `hidesFootnoteAsides` で本文のページ割りから脚注 aside を除外できる。
    抑止後に `follow(_:)` を呼べば delegate を再度通さず、履歴を記録して遷移する

    Inspect internal links before navigation with `EPUBInternalLink` and the
    `shouldFollowInternalLink` delegate. Extract footnotes in the same or
    another document with `noteContent(for:)`, and exclude footnote asides
    from body pagination with `hidesFootnoteAsides`. After intercepting a
    link, call `follow(_:)` to navigate and record history without invoking
    the delegate again.

  - 正規化 UTF-16 範囲と reader-view 座標を結ぶ選択 API
    (`currentSelection` / `clearSelection()` /
    `rects(forTextRange:inSpineIndex:)`)と選択変更 delegate

    Selection APIs (`currentSelection` / `clearSelection()` /
    `rects(forTextRange:inSpineIndex:)`) map normalized UTF-16 ranges to
    reader-view coordinates, with a delegate for selection changes.

  - EPUB page-list のラベル一覧・移動・現在位置
    (`printPageLabels` / `go(toPrintPage:)` / `currentPrintPage`)に対応し、
    本文の pagebreak marker とノンブル表示にも連動

    EPUB page-list support includes labels, navigation, and the current
    position (`printPageLabels` / `go(toPrintPage:)` / `currentPrintPage`),
    integrated with pagebreak markers in the body and folio display.

  - VoiceOver への確定ページ通知と accessibility label/value、システムの
    コントラスト増加・色以外での区別へ追従

    Announces settled pages to VoiceOver, provides accessibility labels and
    values, and follows the system's Increase Contrast and Differentiate
    Without Color settings.

  - 全文ページ数の census は、欠落または決定的に読み込めない spine 項目を
    1 ページとして残りの計測を続け、部分的な結果も利用可能にする

    The whole-book page-count census treats a missing spine item or one with
    a deterministic load failure as one page and continues measuring the
    rest, making partial results available.

  - **ピンチでフォント倍率**(0.5〜3.0 倍): ジェスチャ中は
    `WKWebView.magnification` で滑らかに視覚追従し、指を離すと倍率を確定して
    進行率を保ったまま再ページ割り(テキストは再流し込みでシャープなまま)。
    `adjustFontScale(by:)` で段階調整も可、変更は delegate へ通知

    **Pinch to adjust font scale** (0.5–3.0×): `WKWebView.magnification`
    provides smooth visual feedback during the gesture. On release, the
    scale is committed and the content is repaginated while preserving
    progression; reflow keeps the text sharp. `adjustFontScale(by:)` also
    supports incremental adjustments, with changes reported to the delegate.

  - ホスト統合: キー/クリック/ファイルドロップの delegate 転送と、
    `EPUBContextMenuPolicy` / 表示直前 delegate によるコンテキストメニュー制御
    (アプリ独自のキーバインドやページ送りに接続できる。既定では
    左右端タップでページ送り)。キーは `forwardsKeyEventsNatively` で
    ネイティブ `NSEvent` を横取り転送でき、WKWebView にキーを食われる
    問題を避けられる(ホスト独自バインド向けの推奨経路)

    Host integration: forwards key, click, and file-drop events to delegates,
    and controls context menus with `EPUBContextMenuPolicy` and a delegate
    called just before presentation. Connect these to app-specific key
    bindings or page turning; tapping the left or right edge turns pages by
    default. `forwardsKeyEventsNatively` intercepts and forwards native
    `NSEvent` key events so WKWebView does not consume them, the recommended
    path for host-specific bindings.

- **固定レイアウト**: viewport 解析、`page-spread-left/right/center`、
  「画像 1 枚だけのページ」の検出(WebKit を介さず画像を直接取り出せる —
  日本の漫画 EPUB の大多数がこの形)、複雑ページの
  オフスクリーンラスタライズ(`EPUBPageRasterizer`)。`device-width` /
  `device-height` の viewport はライブ表示の領域へ追従し、ラスタライズ時は
  `deviceViewportSize` で描画先寸法を渡せる。
  `FixedLayoutPageInfo.viewportIsDeviceSized` で該当ページを判別できる

  **Fixed-layout**: viewport parsing, `page-spread-left/right/center`,
  detection of single-image pages (extract images directly without WebKit;
  most Japanese manga EPUBs use this form), and offscreen rasterization of
  complex pages (`EPUBPageRasterizer`). A `device-width` / `device-height`
  viewport follows the live display area; for rasterization, pass the target
  dimensions with `deviceViewportSize`. Identify these pages with
  `FixedLayoutPageInfo.viewportIsDeviceSized`.

- 文書全体に加えて itemref ごとの `rendition:spread-*` も文書順に解決し、
  現在項目の表示と項目別 census の単ページ／見開き計画へ反映

  Resolves per-itemref `rendition:spread-*` in document order in addition to
  publication-wide settings, and applies them to the current item's display
  and the single-page / spread plan for each spine item's census.

## 導入 / Installation

SwiftPM で依存に追加する:

Add Washi as a SwiftPM dependency:

```swift
// Package.swift
.package(url: "https://github.com/shunnag/Washi.git", from: "1.0.0")
```

通常利用するプロダクトは 2 つ:

Two products cover typical use cases:

- **`WashiCore`** — 解析層のみ(Foundation / CoreFoundation / Compression /
  CryptoKit / CoreGraphics / ImageIO)。AppKit/WebKit を引かないので、GUI セッションの
  ない**ヘッドレス利用**(CLI・索引・サーバ・変換ツール)で使える。
  OCF/OPF/nav 解析・メタデータ・本文抽出/検索・表紙デコードまで。

  **`WashiCore`** — the parsing layer only (Foundation / CoreFoundation /
  Compression / CryptoKit / CoreGraphics / ImageIO). It does not link AppKit
  or WebKit, so it supports **headless use** without a GUI session: CLI tools,
  indexing, servers, and converters. Includes OCF/OPF/nav parsing, metadata,
  text extraction and search, and cover decoding.

- **`Washi`** — 表示層込み(AppKit / WebKit を追加。リーダービュー・
  ページ census・サムネイル)。`WashiCore` を再輸出するので、
  **`import Washi` だけで両層の公開 API が見える**(従来どおり)。

  **`Washi`** — includes the rendering layer (adds AppKit / WebKit for the
  reader view, page census, and thumbnails). It re-exports `WashiCore`, so
  **`import Washi` exposes the public APIs of both layers**, as before.

```swift
// ヘッドレス: 解析・メタデータ・検索のみ
// Headless: parsing, metadata, and search only.
import WashiCore
let book = try EPUBPublication(url: url)
print(book.metadata.mainTitle ?? "", book.search("keyword").count)
```

このほか、`WashiDynamic` は動的ライブラリとして 1 本にまとめたいホスト
(フレームワーク同梱など)向けで、両ターゲットを含む。

`WashiDynamic` includes both targets for hosts that want a single dynamic
library, for example when bundling a framework.

## 使い方 / Usage

```swift
import Foundation
import Washi

// 解析(UI からは非同期の open を推奨。重い解析をメインで走らせない)
// Parse (prefer async open from UI code to keep heavy parsing off the main
// thread).
let publication = try await EPUBPublication.open(url: epubURL)
print(publication.metadata.mainTitle ?? "")
// 常に .ltr または .rtl
// Always .ltr or .rtl.
print(publication.effectiveReadingDirection)
// 判定に使った出典
// The source used to determine the direction.
print(publication.effectiveReadingDirectionSource)
for item in publication.navigation.toc { print(item.title) }

// 表示(AppKit)
// Display (AppKit).
let reader = EPUBReaderView()
reader.delegate = self
// at: EPUBLocator で位置復元
// Restore a position by passing an EPUBLocator to at:.
reader.load(publication: publication)
// 読書順で次ページ
// Next page in reading order.
reader.goForward()
// 物理方向(右綴じなら「進む」)
// Physical direction (forward for a right-bound book).
reader.turnPageLeft()

// 表紙(ライブラリ一覧用。宣言がない本もフォールバック連鎖で解決)
// Cover (for library listings; a fallback chain handles books without a
// cover declaration).
let cover = publication.coverImage(maxPixelSize: 480)   // CGImage?

// 本文抽出・全文検索(WebKit 不要。索引・検索・引用に)
// Text extraction and full-text search (no WebKit; for indexing, searching,
// and quoting).
let plain = try publication.extractText(forSpineIndex: 0)
// 大小・全半角無視
// Case- and character-width-insensitive.
for hit in publication.search("吾輩") {
    print(hit.spineIndex, hit.characterOffset, hit.snippet)
}

// 固定レイアウトの画像直取り
// Extract a fixed-layout image directly.
let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
if let path = info.simpleImagePath {
    // PNG/JPEG そのもの
    // The original PNG/JPEG data.
    let (data, _) = try publication.resource(at: path)
}
```

ジャンプ履歴の利用可否は delegate で UI へ同期できる。通常のページ送りは
この履歴に入らない。

Use the delegate to keep the UI in sync with navigation history availability.
Normal page turns are not added to this history.

```swift
func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {
    print("戻る操作:", view.canGoBack ? "有効" : "無効")
}

if reader.canGoBack {
    reader.goBack()
}
```

`noteref` は既定遷移を止め、ホストのポップオーバーへ表示できる。
`presentFootnote(_:anchor:)` はホスト側の表示処理とする。

Intercept the default navigation for a `noteref` and show the note in a host
popover. `presentFootnote(_:anchor:)` represents the host's presentation code.

```swift
func readerView(
    _ view: EPUBReaderView,
    shouldFollowInternalLink link: EPUBInternalLink
) -> Bool {
    guard link.isNoteReference else { return true }
    Task { @MainActor in
        if let note = await view.noteContent(for: link) {
            presentFootnote(note, anchor: link.anchorRect)
        }
    }
    return false
}

var footnoteSettings = reader.settings
footnoteSettings.hidesFootnoteAsides = true
reader.settings = footnoteSettings

// ポップオーバーの「本文で開く」操作などから呼ぶ
// Call from an action such as "Open in text" in the popover.
func openFootnoteInReader(_ link: EPUBInternalLink) {
    reader.follow(link)
}
```

文字組み設定はまとめて代入すると、1 回の再ページ割りで反映できる。
`letterSpacingEm` は CJK の縦組みには適用されない。

Assign typography settings together to apply them in a single repagination.
`letterSpacingEm` is not applied to vertical CJK text.

```swift
var typography = reader.settings
typography.lineHeightScale = 1.1
typography.letterSpacingEm = 0.03
typography.paragraphSpacingEm = 0.8
typography.fontFamilyOverride = "Hiragino Mincho ProN"
typography.hidesRuby = false
reader.settings = typography
```

選択範囲は正規化済み UTF-16 オフセットと reader-view 座標で通知される。

Selections are reported as normalized UTF-16 offsets and reader-view
coordinates.

```swift
func readerView(
    _ view: EPUBReaderView,
    selectionDidChange selection: EPUBTextSelection?
) {
    guard let selection else { return }
    print(selection.spineIndex, selection.text,
          selection.utf16Range, selection.rects)
}
```

census は `load(publication:)` の後に復元する。`metricsKey` には
`EPUBScreenMetrics.paginationVersion` が含まれ、古いページ割り方式の記録は
`importCensus(_:)` が自動的に拒否する。現在と異なる表示メトリクスの記録は、
同じ本・同じ世代なら受け入れられ、メトリクスが一致した時点で使われる。

Restore the census after `load(publication:)`. The `metricsKey` includes
`EPUBScreenMetrics.paginationVersion`, so `importCensus(_:)` automatically
rejects records from older pagination algorithms. Records with different
display metrics are accepted for the same book and pagination version, and
are used once the metrics match.

```swift
reader.load(publication: publication)
if let savedRecord = try? JSONDecoder().decode(
    EPUBCensusRecord.self, from: savedCensusData
) {
    let accepted = reader.importCensus(savedRecord)
    print("census 復元:", accepted)
}

if let currentRecord = reader.exportCensus() {
    let dataToPersist = try JSONEncoder().encode(currentRecord)
    // dataToPersist をホスト側で保存する
    // Persist dataToPersist in the host.
}
```

## 対応状況(EPUB 3.3 RS チェックリスト抜粋) / Support Status (EPUB 3.3 RS Checklist Excerpt)

主な EPUB 3.3 RS 要件の対応状況を以下に示す。✅ は対応済みを示す。

The table below summarizes support for selected EPUB 3.3 RS requirements.
✅ indicates support.

| 領域 | 状態 |
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
| メディアオーバーレイ(SMIL) | パース+項目取得(`mediaOverlay`)。1.8.0 から `playMediaOverlay()` / `pauseMediaOverlay()` / `stopMediaOverlay()` で再生し、active-class ハイライトと自動ページ追従に対応 |
| DRM(ADEPT / LCP / FairPlay) | 非対応(検出して報告) |
| リフロー見開き(横組み / 縦組み) | ✅ |
| FXL 見開き合成 | 未実装(ホスト側で合成可) |

scripted コンテンツは任意で有効化できる(既定オフ)。メディアオーバーレイは
解析・項目取得に加え、1.8.0 から再生・ハイライト・自動ページ追従に対応する。
DRM は検出・報告のみで、FXL 見開き合成はホスト側で行う必要がある。

Scripted content can be enabled optionally and is off by default. Media
overlays support parsing and clip retrieval, with playback, highlighting,
and automatic page following since 1.8.0. DRM is only detected and reported;
FXL spread composition must be handled by the host.

## 既知の制限 / Known Limitations

- `text-spacing-trim` は WebKit に未実装のため、指定しても反映されない。

  `text-spacing-trim` has no effect because WebKit does not implement it.

- `hanging-punctuation: force-end` は WebKit では効果がない。

  `hanging-punctuation: force-end` has no effect in WebKit.

- EPUB 3.4 で outdated とされた機能のうち、`rendition:spread` /
  `rendition:flow` / `rendition:orientation` は legacy hint として保持し、
  フォント難読化・NCX・OPF 2 の `meta` は互換性のため引き続き対応する。
  `collection` 要素には未対応。

  Among the features marked outdated in EPUB 3.4, `rendition:spread`,
  `rendition:flow`, and `rendition:orientation` are retained as legacy hints.
  Font obfuscation, NCX, and OPF 2 `meta` remain supported for compatibility.
  The `collection` element is not supported.

- `rendition:flow` の scrolled モード(`scrolled-doc` / `scrolled-continuous`)は
  まだ実装していない。

  The scrolled modes of `rendition:flow` (`scrolled-doc` /
  `scrolled-continuous`) are not yet implemented.

- `defersTapsForDoubleClick = true` は、ダブルクリックによる単語選択より先に
  ページ送りが起きるのを防ぐ代わりに、primary click の通知をシステムの
  ダブルクリック間隔だけ遅らせる。既定の `false` はクリックを即時通知する。

  `defersTapsForDoubleClick = true` prevents a page turn from occurring before
  double-click word selection, but delays primary-click notifications by the
  system double-click interval. The default, `false`, reports clicks
  immediately.

- `invertsGlyphImagesInDark` の外字判定はクラス名と表示寸法に基づくため、
  小さな挿絵を外字と誤判定する場合がある。原色が必要な本では `false` にする。

  `invertsGlyphImagesInDark` identifies glyph images by class names and
  rendered dimensions, so it may misclassify small illustrations. Set it to
  `false` for books that need their original image colors.

- WebRTC コンストラクタの無効化は `allowsScriptedContent = true` で著者
  JavaScript を許可した EPUB コンテンツだけが対象で、ホストアプリや別の
  WebView に対する一般的な WebRTC 制御ではない。

  WebRTC constructors are disabled only in EPUB content where authored
  JavaScript is allowed with `allowsScriptedContent = true`. This is not a
  general WebRTC control for the host app or other WebViews.

## 開発 / Development

- 公開コーパスのヘッドレススモークテストは、`WASHI_CORPUS_DIR` に EPUB
  コーパスのディレクトリを指定して `swift test --filter CorpusSmokeTests` を
  実行する。未設定またはディレクトリが存在しない場合はスキップされる。

  To run headless smoke tests against a public corpus, set `WASHI_CORPUS_DIR`
  to the EPUB corpus directory and run `swift test --filter CorpusSmokeTests`.
  The tests are skipped if the variable is unset or the directory does not
  exist.

- cooViewer の `Scripts/make-jp-epub-fixtures.py` で、日本語 EPUB の
  合成フィクスチャを生成できる。このスクリプトは Washi には含まれない。
  cooViewer リポジトリのルートで、第三者パッケージ不要の次のコマンドを実行する。

  cooViewer's `Scripts/make-jp-epub-fixtures.py` generates synthetic Japanese
  EPUB fixtures. This script is not included in Washi. Run the following
  command from the cooViewer repository root; no third-party packages are
  required.

  ```sh
  python3 Scripts/make-jp-epub-fixtures.py <outdir> [--big]
  ```

## 動作環境 / Requirements

macOS 14+ / Swift 6(strict concurrency)/ Apple Silicon・Intel 両対応の
ソースだが、cooViewer 同梱ビルドは arm64 のみ。

The source supports macOS 14+, Swift 6 with strict concurrency, and both
Apple Silicon and Intel. The build bundled with cooViewer is arm64-only.

## 組み込みの注意(オフスクリーン WebKit) / Integration Notes (Offscreen WebKit)

- 消費者が保持するオフスクリーン型 `EPUBScreenAtlas`(census と
  サムネイルを内部に持つ)と `EPUBPageRasterizer` は、それぞれ不可視の
  NSWindow + WebContent プロセスを抱える。アトラス内部の census／サムネイルは
  完了後 20 秒のアイドルで WebKit を自動解放し、次回要求で再構築するが、
  **使い終えたオフスクリーン型には `invalidate()` を呼ぶ**(アトラスを
  キャッシュから追い出すときも)。`EPUBReaderView` は
  ウインドウから外れた時点で自分のオフスクリーン(内部の census・
  サムネイルレンダラ含む)を自動で畳むので、明示呼び出しは不要

  The offscreen types retained by the caller, `EPUBScreenAtlas` (which holds
  the census and thumbnails) and `EPUBPageRasterizer`, each own an invisible
  NSWindow and WebContent processes. The atlas's internal census and thumbnail
  components automatically release WebKit after 20 seconds of idle time
  following completion and rebuild it on the next request. Even so, **call
  `invalidate()` when finished with an offscreen type**, including when
  evicting an atlas from a cache. `EPUBReaderView` automatically tears down
  its offscreen resources, including its internal census and thumbnail
  renderers, when removed from a window; no explicit call is needed.

- オフスクリーン系 API は **`.userInitiated` 以上の優先度で呼ぶ**こと。
  低 QoS(`.utility` 等)を継いだまま最初の JS 実行を発行すると、WebKit の
  応答が返らず永久待ちになる(実測)

  **Call offscreen APIs at `.userInitiated` priority or higher.** Issuing the
  first JavaScript execution while inheriting a low QoS such as `.utility`
  can leave WebKit unresponsive and cause an indefinite wait, as observed in
  testing.

- 表示・計測系(Rendering/)は全て `@MainActor`。GUI セッションのないデーモン
  からは解析層(`EPUBPublication` ほか)だけを使う

  All rendering and measurement APIs (Rendering/) are `@MainActor`. Daemons
  without a GUI session should use only the parsing layer (`EPUBPublication`
  and related types).

- 全文ページ数の実測(census)はオフスクリーン WebKit で数秒かかることが
  ある。`EPUBReaderView.exportCensus()` の結果を保存し、再オープン時に
  `importCensus(_:)` で注入すると再実測を省ける。同一版かつ現行の
  `paginationVersion` の記録だけを受け入れ、メトリクスも一致すれば
  ページ番号／バーへ即時反映する

  Measuring the whole-book page count (census) with offscreen WebKit can take
  several seconds. Persist the result of `EPUBReaderView.exportCensus()` and
  inject it with `importCensus(_:)` when reopening to skip remeasurement.
  Only records for the same edition and the current `paginationVersion` are
  accepted. If the metrics also match, the page number and page bar update
  immediately.

## ドキュメント / Documentation

公開 API の doc コメントと DocC カタログ記事は、日本語を正(ベース)として
英語を併記する方針で、後続の文書整備で順次対応する。DocC では両者を合わせて
ドキュメントを生成できる。

Public API doc comments and DocC catalog articles will use Japanese as the
authoritative base, with English alongside it. This policy will be applied
in subsequent documentation updates. DocC can generate documentation from
both the comments and the articles.

Swift Package Index 用の設定(`.spi.yml`)では、Washi / WashiCore の両ターゲットを
ドキュメント生成対象に指定している。公開時の
[パッケージ登録](https://swiftpackageindex.com/add-a-package)もここから行える。

The Swift Package Index configuration (`.spi.yml`) enables documentation
generation for both Washi and WashiCore. When publishing, use the
[package registration page](https://swiftpackageindex.com/add-a-package)
to register the package.

Washi パッケージのルートで、ローカルの DocC を次のコマンドでビルドできる。

Build DocC documentation locally from the Washi package root with:

```sh
xcodebuild docbuild -scheme Washi -destination 'platform=macOS'
```

## 開発体制 / Project Organization

このリポジトリが Washi の正リポジトリであり、開発もここで行う。
Issue / PR はこのリポジトリで受け付ける。
[cooViewer](https://github.com/shunnag/cooViewer) は、このパッケージの利用者のひとつ。

This is Washi's canonical repository, where development takes place and
issues and pull requests are accepted.
[cooViewer](https://github.com/shunnag/cooViewer) is one of the applications
that uses this package.

## ライセンス / License

MIT License(LICENSE を参照)。依存パッケージはない。
設計にあたり Readium CSS・Bibi(いずれも実装は独立)の公開知見を参考にした。

MIT License (see LICENSE). There are no package dependencies. The design
draws on publicly shared findings from Readium CSS and Bibi; Washi's
implementation is independent of both.
