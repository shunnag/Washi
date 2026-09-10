# ``WashiCore``

AppKit や WebKit を使わずに、EPUB 出版物を解析・調査・検索できます。

Parse, inspect, and search EPUB publications without AppKit or WebKit.

## 概要 / Overview

WashiCore は Washi のヘッドレス層です。ZIP 形式の EPUB ファイル、展開済みの
EPUB ディレクトリ、メモリ上の EPUB データを開き、パッケージ、
ナビゲーション、アクセシビリティ、暗号化、メディアオーバーレイの
メタデータを提供します。また、リソースと locator の解決、表紙のデコード、
出版物のテキストの抽出や検索を行います。

WashiCore is Washi's headless layer. It opens zipped EPUB files, unpacked EPUB
directories, and in-memory EPUB data; exposes package, navigation,
accessibility, encryption, and media-overlay metadata; resolves resources and
locators; decodes covers; and extracts or searches publication text.

UI コードでは ``EPUBPublication/open(url:readStrategy:)`` を使い、
コンテナと XML の解析を main actor の外で実行してください。

Use ``EPUBPublication/open(url:readStrategy:)`` from UI code so container and
XML parsing runs outside the main actor:

```swift
import WashiCore

let publication = try await EPUBPublication.open(url: epubURL)
print(publication.metadata.mainTitle ?? "Untitled")

for hit in publication.search("paper") {
    print(hit.spineIndex, hit.utf16Range, hit.snippet)
}
```

## Topics

### 出版物を開く / Opening Publications

- ``EPUBPublication``
- ``EPUBReadStrategy``
- ``EPUBError``
- ``ReadingOrderItem``
- ``EPUBLocator``
- ``FixedLayoutPageInfo``
- ``PageSpreadSlot``

### パッケージのメタデータ / Package Metadata

- ``EPUBPackage``
- ``EPUBMetadata``
- ``EPUBAccessibility``
- ``EPUBTitle``
- ``EPUBCreator``
- ``EPUBIdentifier``
- ``EPUBCollectionMembership``
- ``EPUBMetaItem``
- ``ManifestItem``
- ``SpineItemRef``
- ``EPUBSpine``

### 表示形式と綴じ方向 / Rendition and Direction

- ``PageProgressionDirection``
- ``EPUBReadingDirectionSource``
- ``EPUBTextDirection``
- ``RenditionProperties``
- ``RenditionLayout``
- ``RenditionOrientation``
- ``RenditionSpread``
- ``RenditionFlow``

### ナビゲーションとテキスト / Navigation and Text

- ``EPUBNavigation``
- ``EPUBNavItem``
- ``EPUBFlatTOCEntry``
- ``EPUBSearchOptions``
- ``EPUBSearchHit``

### コンテナとリソース / Container and Resources

- ``ZipArchive``
- ``ZipEntryInfo``
- ``ZipError``
- ``ContainerPath``
- ``EPUBMediaType``
- ``EPUBEncryptionInfo``
- ``FontDeobfuscator``
- ``MediaOverlay``
