# ``Washi``

リフローおよび固定レイアウトの EPUB 出版物に対応した、macOS ネイティブの
読書体験を構築できます。

Build native macOS reading experiences for reflowable and fixed-layout EPUB publications.

## 概要 / Overview

Washi は `WashiCore` のヘッドレス解析 API に、AppKit と WebKit を使った
描画層を組み合わせています。対話型のリーダーには ``EPUBReaderView``、
リーダーの外で本の表示を計画して描画するには ``EPUBScreenAtlas``、
複雑な固定レイアウトのページには ``EPUBPageRasterizer`` を使います。

Washi combines the headless parsing APIs from `WashiCore` with an AppKit and
WebKit rendering layer. Use ``EPUBReaderView`` for an interactive reader,
``EPUBScreenAtlas`` to plan and render a book outside the reader, and
``EPUBPageRasterizer`` for complex fixed-layout pages.

リーダー、atlas、ページラスタライザは main actor に分離されています。
リーダーやオフスクリーンレンダラに渡す前に、
`EPUBPublication.open(url:readStrategy:)` で出版物を非同期に開いてください。

The reader, atlas, and page rasterizer are main-actor isolated. Open
publications asynchronously with `EPUBPublication.open(url:readStrategy:)`
before handing them to a reader or an offscreen renderer.

### ガイド / Guides

- <doc:GettingStarted>
- <doc:Footnotes>
- <doc:Pagination>

## Topics

### 読書 / Reading

- ``EPUBReaderView``
- ``EPUBReaderViewDelegate``
- ``EPUBTextSelection``
- ``EPUBTextRangeLanding``
- ``EPUBKeyEvent``
- ``EPUBClickEvent``

### ナビゲーション / Navigation

ナビゲーションの位置と目次の項目には、WashiCore から再エクスポートされる
`EPUBLocator` 型と `EPUBNavItem` 型を使います。

Navigation positions and table-of-contents entries use the re-exported
`EPUBLocator` and `EPUBNavItem` types from WashiCore.

- ``EPUBInternalLink``
- ``EPUBNoteContent``

### 設定 / Settings

- ``EPUBReaderSettings``
- ``EPUBReaderInsets``
- ``EPUBReaderTheme``
- ``EPUBPageTurnStyle``
- ``EPUBColumnMode``
- ``EPUBRGBAColor``
- ``EPUBContextMenuPolicy``

### アクセシビリティ / Accessibility

``EPUBReaderView`` はネイティブのアクセシビリティメタデータと、
ページ変更の読み上げ通知を提供します。出版物で宣言されたアクセシビリティの
メタデータは、WashiCore から再エクスポートされる `EPUBAccessibility` 型で
取得できます。

``EPUBReaderView`` exposes native accessibility metadata and page-change
announcements. Publication-declared accessibility metadata is available as the
re-exported `EPUBAccessibility` type from WashiCore.

### オフスクリーン描画 / Offscreen Rendering

- ``EPUBScreenAtlas``
- ``EPUBScreenMetrics``
- ``EPUBCensusRecord``
- ``EPUBPageRasterizer``
- ``EPUBSchemeHandler``

### 基盤となる解析 API / Core Parsing

再エクスポートされる `WashiCore` モジュールは、`EPUBPublication`、
`EPUBPackage`、`EPUBMetadata`、`EPUBNavigation`、`EPUBSearchOptions`、
`EPUBSearchHit`、`MediaOverlay`、`EPUBEncryptionInfo` を提供します。
各シンボルのドキュメントは WashiCore カタログにあります。

The re-exported `WashiCore` module provides `EPUBPublication`, `EPUBPackage`,
`EPUBMetadata`, `EPUBNavigation`, `EPUBSearchOptions`, `EPUBSearchHit`,
`MediaOverlay`, and `EPUBEncryptionInfo`. Their symbol documentation is in the
WashiCore catalog.
