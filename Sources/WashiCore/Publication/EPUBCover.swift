import CoreGraphics
import Foundation
import ImageIO

extension EPUBPublication {
    /// 表紙画像のコンテナ内パス。
    ///
    /// Container path of the cover image.
    public var coverImagePath: String? {
        guard let item = package.coverImageItem else { return nil }
        return ContainerPath.resolve(base: package.path, href: item.href)
    }

    /// フォールバック連鎖で表紙画像のコンテナ内パスを解決する。ライブラリの
    /// 一覧表示で、表紙を宣言していない実在の本でも表紙を示せるようにする。
    /// 解決は次の順に行う。
    ///
    /// Resolves the cover image's container path through a fallback chain (for
    /// library listings: surface a cover even for real-world books that never
    /// declare one):
    ///
    /// ① マニフェストの properties="cover-image" / EPUB 2 の meta name="cover"
    ///    manifest properties="cover-image" / EPUB 2 meta name="cover"
    /// ② epub:type="cover" のランドマークのリンク先(画像自体、または
    ///    文書内の唯一の画像)
    ///    the target of a landmark with epub:type="cover" (the image itself, or
    ///    the sole image within the document)
    /// ③ id またはファイル名に "cover" を含むマニフェストの画像項目
    ///    a manifest image item whose id or file name contains "cover"
    /// ④ 最初の spine 項目が画像だけのページなら、その画像
    ///    the first spine item's image, if that item is a single-image page
    public var resolvedCoverImagePath: String? {
        if let path = coverImagePath { return path }
        if let path = landmarkCoverPath { return path }
        if let item = package.manifest.first(where: { item in
            item.mediaType.hasPrefix("image/")
                && item.id.lowercased().contains("cover")
        }) ?? package.manifest.first(where: { item in
            item.mediaType.hasPrefix("image/")
                && (item.href.split(separator: "/").last ?? "")
                    .lowercased().contains("cover")
        }) {
            return ContainerPath.resolve(base: package.path, href: item.href)
        }
        if let info = try? fixedLayoutInfo(forSpineIndex: 0),
           let imagePath = info.simpleImagePath {
            return imagePath
        }
        return nil
    }

    /// landmarks の epub:type="cover" 経由の表紙解決(②)
    private var landmarkCoverPath: String? {
        guard let landmark = navigation.landmarks.first(where: {
            $0.epubType?.components(separatedBy: .whitespaces)
                .contains("cover") == true
        }), let href = landmark.href else { return nil }
        let raw = href.split(separator: "#").first.map(String.init) ?? href
        guard let docPath = ContainerPath.resolve(
            base: navigation.basePath, href: raw) else { return nil }
        let mediaType = manifestByPath[docPath]?.mediaType
            ?? EPUBMediaType.guessed(fromPath: docPath)
        if mediaType.hasPrefix("image/") { return docPath }
        // 表紙ページ(XHTML)の中の唯一の画像を表紙とみなす
        guard mediaType == EPUBMediaType.xhtml,
              let (data, _) = try? resource(at: docPath),
              let document = try? WashiXML.document(from: data),
              let root = document.rootElement(),
              let body = root.firstDescendant(localName: "body") else { return nil }
        let imgs = body.descendants(localName: "img")
        if imgs.count == 1, let src = imgs[0].attr("src") {
            return ContainerPath.resolve(base: docPath, href: src)
        }
        let svgImages = body.descendants(localName: "image")
        if imgs.isEmpty, svgImages.count == 1 {
            let href = svgImages[0].xlinkHref
            return href.flatMap { ContainerPath.resolve(base: docPath, href: $0) }
        }
        return nil
    }

    /// 表紙画像をデコードして返す(ImageIO だけを使い、WebKit/AppKit は不要なので
    /// ヘッドレスの索引作成ツールでも動く)。maxPixelSize を渡すと、EXIF の回転を
    /// 適用したうえで、長辺がそのピクセル数以下のサムネイルに縮小する。
    /// 表紙を解決できない、デコードできない(SVG など)、または DRM により読めない
    /// 場合は nil を返す。
    ///
    /// Decodes and returns the cover image (ImageIO only, no WebKit/AppKit, so
    /// it works from headless indexing tools too). Passing maxPixelSize scales
    /// it down to a thumbnail whose long edge is at most that many pixels (with
    /// EXIF rotation applied). Returns nil when the cover cannot be resolved,
    /// cannot be decoded (e.g. SVG), or is unreadable due to DRM.
    public func coverImage(maxPixelSize: Int? = nil) -> CGImage? {
        guard let path = resolvedCoverImagePath,
              let (data, _) = try? resource(at: path),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 解決した表紙画像をデコードせず、生のバイト列とメディアタイプで返す。
    /// 元ファイルをそのまま保存・配信したいとき(ライブラリのキャッシュや Web の
    /// レスポンスなど)に使える。``coverImage(maxPixelSize:)`` と同じ
    /// フォールバック連鎖を使う。表紙が見つからない、または DRM などで読めない
    /// 場合は nil。
    ///
    /// The resolved cover image's raw bytes and media type, without decoding —
    /// useful to store or serve the original file as-is (e.g. a library cache
    /// or a web response). Uses the same fallback chain as
    /// ``coverImage(maxPixelSize:)``.
    /// Nil if no cover resolves or it cannot be read (e.g. DRM).
    public func coverImageData() -> (data: Data, mediaType: String)? {
        guard let path = resolvedCoverImagePath else { return nil }
        return try? resource(at: path)
    }
}
