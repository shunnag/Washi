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

第三者パッケージには依存しません。Foundation・CoreFoundation・zlib(libz)・
CryptoKit・CoreGraphics・ImageIO という OS 標準の構成要素を使い、
ZIP の deflate 展開と CRC-32 検証には zlib を使います。

There are no third-party package dependencies. WashiCore uses the OS-provided
Foundation, CoreFoundation, zlib (libz), CryptoKit, CoreGraphics, and ImageIO.
ZIP deflate decompression and CRC-32 validation use zlib.

UI コードでは ``EPUBPublication/open(url:readStrategy:)`` を使い、
コンテナと XML の解析を main actor の外で実行してください。

Use ``EPUBPublication/open(url:readStrategy:)`` from UI code so container and
XML parsing runs outside the main actor:

```swift
import WashiCore
import Foundation

func inspectBook(at epubURL: URL) async throws {
    let publication = try await EPUBPublication.open(url: epubURL)
    print(publication.metadata.mainTitle ?? "Untitled")
    let hits = await Task.detached(priority: .userInitiated) {
        publication.search("paper")
    }.value
    for hit in hits {
        print(hit.spineIndex, hit.utf16Range, hit.snippet)
    }
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
- ``EPUBHighlight``

### コンテナとリソース / Container and Resources

- ``ZipArchive``
- ``ZipEntryInfo``
- ``ZipError``
- ``ContainerPath``
- ``EPUBMediaType``
- ``EPUBPrefixedCSS``
- ``EPUBEncryptionInfo``
- ``FontDeobfuscator``
- ``MediaOverlay``
