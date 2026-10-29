import CoreGraphics
import Foundation
import ImageIO

/// 見開き内の左右の配置(固定レイアウトの itemref プロパティに基づく)。
///
/// Left/right spread placement (from FXL itemref properties).
public enum PageSpreadSlot: String, Sendable {
    case left, right, center
}

/// 固定レイアウトのページに関する情報。
///
/// Information about a fixed-layout page.
public struct FixedLayoutPageInfo: Sendable {
    public let spineIndex: Int
    /// viewport の meta タグ(または SVG の viewBox)から得たページ寸法(CSS px)。
    ///
    /// Page dimensions (CSS px) from the viewport meta tag (or SVG viewBox).
    public let viewportSize: CGSize?
    /// ビューポートが `device-width` または `device-height` を使い、現在の
    /// 描画先に合わせて寸法を決める必要があるか。
    ///
    /// Whether the viewport uses `device-width` or `device-height` and should
    /// therefore be sized from the current rendering target.
    public let viewportIsDeviceSized: Bool
    /// 画像を 1 枚だけ配置するページの場合、その画像のコンテナ内パス。
    /// この場合は WebKit を使わず画像を直接デコードできる(日本の漫画 EPUB の
    /// 大半がこの構造)。
    ///
    /// The container path of the image when the page merely lays out a single
    /// image; in that case the image can be decoded directly without WebKit
    /// (the vast majority of Japanese manga EPUBs are shaped this way).
    public let simpleImagePath: String?
    public let pageSpread: PageSpreadSlot?
}

/// 「画像 1 枚だけの項目」の判定を項目ごとに一度だけ行うためのキャッシュ。
/// EPUBPublication の Sendable 契約を保つため、可変状態は NSLock の内側だけで扱う
/// (EffectiveReadingDirectionCache と同じ作法)。
final class SingleImageItemCache: @unchecked Sendable {
    private let lock = NSLock()
    private var perItem: [Int: Bool] = [:]

    func value(for index: Int) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return perItem[index]
    }

    func item(_ index: Int, computing loader: () -> Bool) -> Bool {
        lock.lock()
        if let cached = perItem[index] { lock.unlock(); return cached }
        lock.unlock()
        // loader は zip 展開と XML 解析を伴うのでロックの外で回す
        let value = loader()
        // Washi-1mg: 取消しで展開できなかった false を後続の判定に残さない。
        if !Task.isCancelled {
            lock.lock()
            perItem[index] = value
            lock.unlock()
        }
        return value
    }
}

/// Washi-1nm: 寸法・画像判定の値だけを spine 数まで保持し、章データや XML は残さない。
/// EPUBPublication の Sendable 契約を保つため、可変状態は NSLock の内側で扱う。
final class FixedLayoutInfoCache: @unchecked Sendable {
    private let lock = NSLock()
    private let entryLimit: Int
    private var perItem: [Int: FixedLayoutPageInfo] = [:]

    init(entryLimit: Int) { self.entryLimit = max(0, entryLimit) }

    func value(for index: Int) -> FixedLayoutPageInfo? {
        lock.lock()
        defer { lock.unlock() }
        return perItem[index]
    }

    func insert(_ info: FixedLayoutPageInfo, for index: Int) {
        guard (0..<entryLimit).contains(index) else { return }
        lock.lock()
        defer { lock.unlock() }
        if perItem[index] == nil { perItem[index] = info }
    }
}

extension EPUBPublication {
    /// 展開や解析をせず、既に判定済みの値だけを返す。
    package func cachedSingleImageItem(atSpineIndex index: Int) -> Bool? {
        singleImageItemCache.value(for: index)
    }

    /// その spine 項目が「画像 1 枚だけの項目」か(表紙・挿絵・漫画のページ)。
    /// 表示・census・画面サムネイルが同じ答えを共有するよう、項目ごとに一度だけ
    /// 判定してキャッシュする。パッケージ内部の API(公開面は増やさない)。
    /// 初回は章の展開と XML 解析を伴うので、UI からは可能ならメインスレッドの外で呼ぶ。
    package func isSingleImageItem(atSpineIndex index: Int) -> Bool {
        guard readingOrder.indices.contains(index) else { return false }
        return singleImageItemCache.item(index) {
            let entry = readingOrder[index]
            // 画像・SVG の spine 項目は、ヘッダーだけを見る fixedLayoutInfo に任せる
            if EPUBMediaType.normalized(entry.resolvedItem.mediaType).hasPrefix("image/") {
                return (try? fixedLayoutInfo(forSpineIndex: index))?.simpleImagePath != nil
            }
            // 文書は fixedLayoutInfo と同じ判定を、画像要素の名前が現れない章では
            // 解析せずに済ませる(文字だけの大きな章を丸ごと解析しない)
            guard let data = try? resource(at: entry.resolvedContainerPath).data,
                  Self.mayContainImageElement(data),
                  (try? WashiXML.rejectsSingleImageDocument(data)) == false,
                  let root = (try? WashiXML.document(from: data))?.rootElement(),
                  let href = Self.simpleImageHref(in: root) else { return false }
            return ContainerPath.resolve(base: entry.resolvedContainerPath, href: href) != nil
        }
    }

    /// 画像だけの項目の判定に使う要素(img と SVG の image)の名前が、バイト列に
    /// 現れうるか。ASCII と互換な符号化では要素名がそのままのバイトで現れるので、
    /// どちらも無ければ解析しなくても画像だけの項目ではない。UTF-16・UTF-32 は
    /// この方法では判定できないので、解析に回す(true を返す)。
    static func mayContainImageElement(_ data: Data) -> Bool {
        let head = data.prefix(4)
        if head.contains(0) || head.starts(with: [0xFE, 0xFF])
            || head.starts(with: [0xFF, 0xFE]) {
            return true
        }
        return data.range(of: Data("img".utf8)) != nil
            || data.range(of: Data("image".utf8)) != nil
    }

    /// 固定レイアウトのページの構造情報(ビューポート・画像だけのページの検出・
    /// 見開き内の配置)。リフローの本の spine 項目についても、ビューポートなしの
    /// 情報を返す。
    /// 未キャッシュの項目の ZIP 展開中に呼び出し元 Task の取消しを検出すると
    /// `CancellationError` を投げる。
    /// 同じ spine 添字の結果は出版物の生存期間中、spine 数を上限に再利用するため、
    /// フォルダコンテナの内容が途中で変わっても、2 回目以降は最初の値を返す。
    ///
    /// Structural information about an FXL page (viewport, single-image-page
    /// detection, spread placement). Also returns viewport-less info for the
    /// spine items of a reflowable book.
    /// Throws `CancellationError` if cancellation of the calling task is detected
    /// during ZIP decompression of an uncached item.
    /// Results for the same spine index are reused for the publication's lifetime,
    /// bounded by the spine count, so subsequent calls return the initial value
    /// even if a folder container's contents change in the meantime.
    public func fixedLayoutInfo(forSpineIndex index: Int) throws -> FixedLayoutPageInfo {
        guard readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        if let cached = fixedLayoutInfoCache.value(for: index) { return cached }
        // SingleImageItemCache と同じく、展開と解析はロックの外で行う。
        let data = try resource(at: readingOrder[index].resolvedContainerPath).data
        let info = uncachedFixedLayoutInfo(forSpineIndex: index, data: data)
        fixedLayoutInfoCache.insert(info, for: index)
        return info
    }

    /// Washi-1nm: setup の累積展開予算。既知の値は予算を使わず再利用し、
    /// 予算不足はキャッシュに入れない(後から通常の表示経路で正確に取得できる)。
    package func cachedFixedLayoutInfo(forSpineIndex index: Int) -> FixedLayoutPageInfo? {
        fixedLayoutInfoCache.value(for: index)
    }

    package func fixedLayoutInfo(forSpineIndex index: Int,
                                 remainingByteCount: inout Int) throws -> FixedLayoutPageInfo? {
        guard readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        if let cached = fixedLayoutInfoCache.value(for: index) { return cached }
        guard remainingByteCount > 0 else { return nil }
        let path = readingOrder[index].resolvedContainerPath
        let declaredSize = declaredFixedLayoutResourceSize(at: path)
        if let size = declaredSize {
            guard size <= UInt64(remainingByteCount) else {
                remainingByteCount = 0
                return nil
            }
            // 破損 ZIP で展開が失敗しても予算は消費し、同じ失敗を大量に繰り返さない。
            remainingByteCount -= Int(size)
        }
        let data = try resource(at: path).data
        // フォルダや独自 ContainerReader は宣言サイズを持たないため、取得後に
        // 累積する。超過した文書は XML 解析せず、以降の未取得項目も止める。
        if declaredSize == nil {
            guard data.count <= remainingByteCount else {
                remainingByteCount = 0
                return nil
            }
            remainingByteCount -= data.count
        }
        let info = uncachedFixedLayoutInfo(forSpineIndex: index, data: data)
        fixedLayoutInfoCache.insert(info, for: index)
        return info
    }

    /// ContainerReader の公開面を増やさず、ZIP は展開前に中央ディレクトリを参照する。
    /// 救済パスも read と同じ優先順(完全一致・ルート接頭辞・大小文字違い)で調べる。
    private func declaredFixedLayoutResourceSize(at path: String) -> UInt64? {
        guard let reader = container.reader as? RescuingContainerReader,
              let zip = reader.base as? ZipContainerReader else { return nil }
        let candidates: [String?] = [
            path, reader.rootPrefix + path,
            reader.caseInsensitiveIndex[path.lowercased()],
            reader.caseInsensitiveIndex[(reader.rootPrefix + path).lowercased()]
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let info = zip.archive.info(for: candidate) { return info.uncompressedSize }
        }
        return nil
    }

    private func uncachedFixedLayoutInfo(forSpineIndex index: Int,
                                        data: Data) -> FixedLayoutPageInfo {
        let entry = readingOrder[index]
        // page-spread は接頭辞なし(EPUB 3.0 遺物)と rendition: 付き
        // (EPUB 3.1+)の両同義形を受ける
        let props = entry.itemRef.properties
        func hasSpread(_ slot: String) -> Bool {
            props.contains("page-spread-\(slot)")
                || props.contains("rendition:page-spread-\(slot)")
        }
        let spread: PageSpreadSlot?
        if hasSpread("left") {
            spread = .left
        } else if hasSpread("right") {
            spread = .right
        } else if hasSpread("center") {
            spread = .center
        } else {
            spread = nil
        }

        let resolvedPath = entry.resolvedContainerPath
        let mediaType = EPUBMediaType.normalized(entry.resolvedItem.mediaType)
        // cooViewer-oxr.15: Core 画像が spine 自身なら ImageIO のヘッダー情報
        // だけで自然寸法を得て、WebKit を通さず画像そのものを表示できる。
        if mediaType.hasPrefix("image/"), mediaType != EPUBMediaType.svg {
            return FixedLayoutPageInfo(
                spineIndex: index, viewportSize: Self.imagePixelSize(data),
                viewportIsDeviceSized: false, simpleImagePath: resolvedPath,
                pageSpread: spread)
        }
        // cooViewer-oxr.91: SVG 単体 spine 項目も単一 image ラッパーなら
        // 参照画像を直接デコードできる。
        if mediaType == EPUBMediaType.svg {
            let document = try? WashiXML.document(from: data)
            let root = document?.rootElement()
            let size = root.flatMap(Self.svgSize)
            let imagePath = root.flatMap(Self.simpleSVGImageHref).flatMap {
                ContainerPath.resolve(base: resolvedPath, href: $0)
            }
            return FixedLayoutPageInfo(
                spineIndex: index, viewportSize: size,
                viewportIsDeviceSized: false, simpleImagePath: imagePath,
                pageSpread: spread)
        }
        guard let document = try? WashiXML.document(from: data),
              let root = document.rootElement() else {
            return FixedLayoutPageInfo(
                spineIndex: index, viewportSize: nil,
                viewportIsDeviceSized: false, simpleImagePath: nil,
                pageSpread: spread)
        }
        let viewport = Self.viewportDescription(in: root)
            ?? package.metadata.rendition.viewport.flatMap(Self.parseViewportDescription)
        let imageHref = Self.simpleImageHref(in: root)
        let imagePath = imageHref.flatMap {
            ContainerPath.resolve(base: resolvedPath, href: $0)
        }
        return FixedLayoutPageInfo(
            spineIndex: index, viewportSize: viewport?.size,
            viewportIsDeviceSized: viewport?.isDeviceSized ?? false,
            simpleImagePath: imagePath, pageSpread: spread)
    }

    /// <meta name="viewport" content="width=1200, height=1920"> の解析
    private static func viewportDescription(in root: XMLElement) -> ParsedViewport? {
        guard let head = root.firstDescendant(localName: "head") else { return nil }
        for meta in head.descendants(localName: "meta") {
            guard meta.attr("name") == "viewport",
                  let content = meta.attr("content") else { continue }
            if let viewport = parseViewportDescription(content) { return viewport }
        }
        return nil
    }

    static func parseViewportContent(_ content: String) -> CGSize? {
        parseViewportDescription(content)?.size
    }

    private struct ParsedViewport {
        let size: CGSize?
        let isDeviceSized: Bool
    }

    /// cooViewer-oxr.50: device-width/device-height は数値欠落ではなく、表示先
    /// 寸法へ追従する明示指定として保持する。
    private static func parseViewportDescription(_ content: String) -> ParsedViewport? {
        var width: Double?
        var height: Double?
        var sawWidth = false
        var sawHeight = false
        var isDeviceSized = false
        for pair in content.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // 最初の width/height 宣言だけを使う(EPUB RS 3.3 §8.1.2)
            if key == "width", !sawWidth {
                sawWidth = true
                if rawValue == "device-width" {
                    isDeviceSized = true
                } else {
                    width = leadingNumber(rawValue)
                }
            }
            if key == "height", !sawHeight {
                sawHeight = true
                if rawValue == "device-height" {
                    isDeviceSized = true
                } else {
                    height = leadingNumber(rawValue)
                }
            }
        }
        if isDeviceSized {
            return ParsedViewport(size: nil, isDeviceSized: true)
        }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return ParsedViewport(size: CGSize(width: width, height: height),
                              isDeviceSized: false)
    }

    /// "500px" → 500 の数値サルベージ(EPUB RS 3.3 §8.1.2 の寛容処理)
    private static func leadingNumber(_ text: String) -> Double? {
        var numeric = ""
        for ch in text {
            if ch.isNumber || (ch == "." && !numeric.contains(".")) {
                numeric.append(ch)
            } else {
                break
            }
        }
        return Double(numeric)
    }

    /// SVG ルートの寸法(viewBox 優先、なければ width/height 属性)
    private static func svgSize(_ root: XMLElement) -> CGSize? {
        if let viewBox = root.attr("viewBox") {
            let numbers = viewBox
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 {
                return CGSize(width: numbers[2], height: numbers[3])
            }
        }
        if let width = root.attr("width").flatMap(parseCSSLength),
           let height = root.attr("height").flatMap(parseCSSLength) {
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private static func parseCSSLength(_ value: String) -> Double? {
        Double(value.trimmingCharacters(
            in: CharacterSet(charactersIn: "pxt ")))
    }

    /// cooViewer-oxr.15: 完全デコードせず ImageIO のプロパティから画素寸法を得る。
    private static func imagePixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        let size = CGSize(width: width.doubleValue, height: height.doubleValue)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// cooViewer-oxr.91: 非描画メタデータを除き、唯一の描画内容が image の
    /// SVG だけを直接画像ページとして扱う。
    private static func simpleSVGImageHref(in root: XMLElement) -> String? {
        guard root.localName?.lowercased() == "svg" else { return nil }
        let ignored: Set<String> = ["title", "desc", "defs", "metadata"]
        let structural: Set<String> = ["svg", "g", "a"]
        var hrefs: [String?] = []
        var hasUnsupportedContent = false

        func inspect(_ element: XMLElement) {
            for node in element.children ?? [] {
                if node.kind == .text {
                    if !(node.stringValue ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty {
                        hasUnsupportedContent = true
                    }
                    continue
                }
                guard node.kind == .element,
                      let child = node as? XMLElement,
                      let localName = child.localName?.lowercased()
                else { continue }
                if ignored.contains(localName) { continue }
                if localName == "text" {
                    hasUnsupportedContent = true
                } else if localName == "image" {
                    hrefs.append(child.xlinkHref)
                } else if structural.contains(localName) {
                    inspect(child)
                } else {
                    hasUnsupportedContent = true
                }
            }
        }

        inspect(root)
        guard !hasUnsupportedContent, hrefs.count == 1,
              let href = hrefs[0]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty else { return nil }
        return href
    }

    /// cooViewer-oxr.6: 可視本文がなく、img / svg image の参照先が
    /// 重複を除いて 1 種類だけの XHTML なら画像 href を返す。
    private static func simpleImageHref(in root: XMLElement) -> String? {
        guard let body = root.firstDescendant(localName: "body") else { return nil }
        // cooViewer-oxr.6: ReaderScripts と同じ可視テキスト・同一 src の判定。
        // style/script や隠された代替文、KCC のパネル用複製で表紙を除外しない。
        guard body.normalizedVisibleText.isEmpty else { return nil }
        let imgs = body.descendants(localName: "img")
        let svgImages = body.descendants(localName: "svg").flatMap { $0.descendants(localName: "image") }
        let sources = imgs.map { $0.attr("src") } + svgImages.map(\.xlinkHref)
        guard !sources.isEmpty, sources.allSatisfy({
            guard let source = $0 else { return false }
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        let uniqueSources = Set(sources.compactMap { $0 })
        return uniqueSources.count == 1 ? uniqueSources.first : nil
    }
}
