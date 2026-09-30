import Foundation

/// spine の 1 項目を読む順序で表したエントリ(マニフェストとパスを解決済み)。
///
/// A reading-order entry for one spine item (manifest- and path-resolved).
public struct ReadingOrderItem: Sendable {
    /// readingOrder 配列内のインデックス(Washi でいう「spine index」。
    /// linear="no" の項目も含む)。
    ///
    /// Index within the readingOrder array (what Washi calls the "spine index"; includes linear="no" items).
    public let spineIndex: Int
    public let itemRef: SpineItemRef
    public let item: ManifestItem
    /// コンテナ内の正規形のパス。
    ///
    /// Canonical path within the container.
    public let containerPath: String
    /// フォールバック連鎖をたどって最初に見つかる、実在する描画可能な
    /// マニフェスト項目。利用可能なフォールバックが不要、または存在しない場合は
    /// ``item`` と同じ。
    ///
    /// The first renderable, existing manifest item reached through the
    /// fallback chain. This equals ``item`` when no usable fallback is needed
    /// or available.
    public let resolvedItem: ManifestItem
    /// ``resolvedItem`` の正規形のパス。描画と本文抽出にはこのパスを使い、
    /// 宣言された spine の識別には引き続き ``containerPath`` を使う。
    ///
    /// Canonical path of ``resolvedItem``. Rendering and content extraction
    /// should use this path while preserving ``containerPath`` as the declared
    /// spine identity.
    public let resolvedContainerPath: String
}

/// EPUB 1 冊を扱う窓口。
/// 開くときに OCF → パッケージ文書 → ナビゲーション → encryption.xml の順に
/// 解析し、変更されない出版物メタデータ(`Sendable`)を公開する。
/// リソースの読み取りと、同期制御された抽出本文キャッシュはスレッドセーフ。
///
/// A facade for a single EPUB book.
/// On open it parses OCF → package document → navigation → encryption.xml,
/// then exposes immutable publication metadata (`Sendable`). Resource reads
/// and the synchronized extracted-text cache are thread-safe.
public final class EPUBPublication: Sendable {
    public let url: URL
    let container: OCFContainer
    public let package: EPUBPackage
    public let navigation: EPUBNavigation
    public let encryption: EPUBEncryptionInfo
    public let readingOrder: [ReadingOrderItem]
    /// コンテナ内パス → マニフェスト項目(メディアタイプ解決用)
    let manifestByPath: [String: ManifestItem]
    /// cooViewer-oxr.8: 目次解決を呼び出しごとの spine 線形走査にしない。
    let spineIndexByContainerPath: [String: Int]
    /// cooViewer-oxr.8: NCX 補完時は toc と nav 補助一覧の基準文書が異なる。
    let tocBasePath: String
    let indexedTOC: [IndexedTOCEntry]
    /// 本文の UTF-8 データを最大 32 MiB、件数は spine 全体を収める枠で FIFO 保持する。
    let extractedTextCache: ExtractedTextCache
    let effectiveReadingDirectionCache = EffectiveReadingDirectionCache()
    let singleImageItemCache = SingleImageItemCache()

    // MARK: - 初期化

    /// 呼び出し元のスレッド外で EPUB を開き、解析済みの出版物を返す。
    ///
    /// Opens an EPUB off the calling thread and returns the parsed publication.
    ///
    /// 大きな本の解析(ZIP 展開・XML 解析)は CPU 負荷が高いため、
    /// `.userInitiated` 優先度の detached task で実行し、メインアクターから
    /// 呼び出しても応答性を保つ。UI コードでは同期イニシャライザよりこちらを推奨。
    ///
    /// Parsing a large book (unzip, XML) is CPU-bound; this runs it at
    /// `.userInitiated` priority on a detached task so callers on the main
    /// actor stay responsive. Prefer this over the synchronous initializer in
    /// UI code.
    ///
    /// - Parameters:
    ///   - url: `.epub` ファイルまたは展開済みの EPUB ディレクトリ。
    ///     a `.epub` file or an unpacked EPUB directory.
    ///   - readStrategy: ディスクからのバイト列の読み込み方
    ///     (``EPUBReadStrategy`` を参照。`.alwaysCopy` は状態が変わりやすい
    ///     ファイルや信頼できないファイルのメモリマップを避ける)。
    ///     how the bytes are read from disk (see
    ///     ``EPUBReadStrategy``; `.alwaysCopy` avoids memory-mapping for
    ///     volatile or untrusted files).
    public static func open(url: URL,
                            readStrategy: EPUBReadStrategy = .mappedIfSafe)
        async throws -> EPUBPublication {
        try await Task.detached(priority: .userInitiated) {
            try EPUBPublication(url: url, readStrategy: readStrategy)
        }.value
    }

    /// `.epub` ファイルまたは展開済みの EPUB ディレクトリを開く。
    /// `readStrategy` でバイト列の読み込み方を指定する(``EPUBReadStrategy`` を参照)。
    ///
    /// Opens a `.epub` file or an already-unpacked EPUB directory.
    /// `readStrategy` controls how the bytes are read (see ``EPUBReadStrategy``).
    public convenience init(url: URL,
                            readStrategy: EPUBReadStrategy = .mappedIfSafe) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory) else {
            throw EPUBError.notAnEPUB(url.path)
        }
        if isDirectory.boolValue {
            try self.init(url: url, reader: FolderContainerReader(
                rootURL: url, readStrategy: readStrategy))
        } else {
            let archive: ZipArchive
            do {
                archive = try ZipArchive(url: url, readStrategy: readStrategy)
            } catch {
                throw EPUBError.notAnEPUB(
                    "Unable to read ZIP: \(error.localizedDescription)")
            }
            try self.init(url: url, reader: ZipContainerReader(archive: archive))
        }
    }

    /// メモリ内の `.epub` データから開く(アーカイブ内に入っている EPUB など)。
    ///
    /// Opens from in-memory `.epub` data (e.g. an EPUB nested inside an archive).
    public convenience init(data: Data, displayURL: URL) throws {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            throw EPUBError.notAnEPUB(
                "Unable to read ZIP: \(error.localizedDescription)")
        }
        try self.init(url: displayURL, reader: ZipContainerReader(archive: archive))
    }

    init(url: URL, reader baseReader: any ContainerReader) throws {
        self.url = url
        // cooViewer-oxr.46 C44: 自炊層の梱包ミス(フォルダごと圧縮・大文字小文字
        // 違い)を、厳密な解決が外れたときだけ救済する。
        let reader: any ContainerReader = RescuingContainerReader(base: baseReader)
        let container = try OCFContainer(reader: reader)
        self.container = container

        // 複数 rootfile は先頭(デフォルトレンディション)を採用(OCF §3.5.2.1)
        guard let packagePath = container.packageDocumentPaths.first,
              reader.exists(packagePath) else {
            throw EPUBError.malformed("Package document not found")
        }
        // cooViewer-oxr.46 C46: iBooks / Kobo の display-options.xml による
        // 固定レイアウト表明はパッケージ文書の外にあるので、ここで読んで渡す。
        let package = try PackageDocumentParser.parse(
            data: reader.read(packagePath), at: packagePath,
            legacyFixedLayoutHint: Self.displayOptionsDeclareFixedLayout(reader: reader))
        self.package = package

        // encryption.xml(なければ空)
        let encryptionPath = "META-INF/encryption.xml"
        if reader.exists(encryptionPath) {
            self.encryption = (try? EPUBEncryptionInfo.parse(
                data: reader.read(encryptionPath))) ?? .empty
        } else {
            self.encryption = .empty
        }

        // 読書順: spine → manifest → コンテナ内パス
        var readingOrder: [ReadingOrderItem] = []
        var manifestByPath: [String: ManifestItem] = [:]
        for item in package.manifest {
            if let path = ContainerPath.resolve(base: packagePath, href: item.href) {
                manifestByPath[path] = item
            }
        }
        for itemRef in package.spine.itemRefs {
            guard let item = package.manifestByID[itemRef.idref],
                  let path = ContainerPath.resolve(base: packagePath, href: item.href)
            else { continue }
            // cooViewer-oxr.16: 宣言項目が非描画形式または欠落なら、fallback
            // 連鎖のうち描画可能かつ実在する最初の項目を表示用に採用する。
            let resolved = Self.resolvedSpineResource(
                for: item, package: package, packagePath: packagePath,
                reader: reader) ?? (item: item, path: path)
            readingOrder.append(ReadingOrderItem(
                spineIndex: readingOrder.count,
                itemRef: itemRef, item: item, containerPath: path,
                resolvedItem: resolved.item,
                resolvedContainerPath: resolved.path))
        }
        guard !readingOrder.isEmpty else {
            throw EPUBError.malformed("Spine is empty")
        }
        self.readingOrder = readingOrder
        self.manifestByPath = manifestByPath

        var spineIndexByContainerPath: [String: Int] = [:]
        for entry in readingOrder {
            // 描画可能な宣言項目でも、代替文書を指す目次・内部リンクを同じ
            // spine へ対応付ける。連鎖が重なる場合は従来の文書順の先勝ちを守る。
            let fallbackPaths = Self.fallbackChain(for: entry.item, package: package)
                .compactMap { ContainerPath.resolve(base: packagePath, href: $0.href) }
            for path in [entry.containerPath, entry.resolvedContainerPath] + fallbackPaths
            where spineIndexByContainerPath[path] == nil {
                spineIndexByContainerPath[path] = entry.spineIndex
            }
        }
        self.spineIndexByContainerPath = spineIndexByContainerPath

        // cooViewer-oxr.9: EPUB 3 nav を優先し、toc が空なら NCX で補完する。
        var navigation = EPUBNavigation()
        if let navItem = package.navItem,
           let navPath = ContainerPath.resolve(base: packagePath, href: navItem.href),
           reader.exists(navPath),
           let parsed = try? NavigationDocumentParser.parse(
               data: reader.read(navPath), at: navPath) {
            navigation = parsed
        }
        var tocBasePath = navigation.basePath
        if navigation.toc.isEmpty {
            let declaredNCX = package.spine.tocItemID
                .flatMap { package.manifestByID[$0] }
            let ncxItem = declaredNCX ?? package.manifest.first {
                $0.mediaType.lowercased() == "application/x-dtbncx+xml"
            }
            if let ncxItem,
               let ncxPath = ContainerPath.resolve(base: packagePath,
                                                   href: ncxItem.href),
               reader.exists(ncxPath),
               let ncx = try? NCXParser.parse(
                   data: reader.read(ncxPath), at: ncxPath) {
                tocBasePath = ncx.basePath
                if navigation.basePath.isEmpty {
                    navigation = ncx
                } else {
                    // cooViewer-oxr.9: nav と NCX の配置先が異なっても、単一の
                    // navigation.basePath から両方を正しく解決できる形へ直す。
                    navigation.toc = Self.rootRelativeNavigationItems(
                        ncx.toc, sourceBasePath: ncx.basePath)
                    if navigation.pageList.isEmpty {
                        navigation.pageList = Self.rootRelativeNavigationItems(
                            ncx.pageList, sourceBasePath: ncx.basePath)
                    }
                    tocBasePath = navigation.basePath
                }
            }
        }
        self.navigation = navigation
        self.tocBasePath = tocBasePath
        self.indexedTOC = Self.indexTOC(
            navigation.toc, basePath: tocBasePath,
            spineIndexByContainerPath: spineIndexByContainerPath)
        // 全項目の順走査で次に必要な本文を件数だけで追い出さない。
        // 空章の管理件数は有限のまま、保持本文の安全上限は引き続き 32 MiB とする。
        self.extractedTextCache = ExtractedTextCache(
            byteLimit: 32 * 1024 * 1024, entryLimit: max(512, readingOrder.count))
    }

    /// META-INF の display-options.xml(Apple / Kobo)が固定レイアウトを表明して
    /// いるか。`<option name="fixed-layout">true</option>` の形。
    private static func displayOptionsDeclareFixedLayout(
        reader: any ContainerReader) -> Bool {
        let paths = ["META-INF/com.apple.ibooks.display-options.xml",
                     "META-INF/com.kobobooks.display-options.xml"]
        for path in paths where reader.exists(path) {
            guard let data = try? reader.read(path),
                  let document = try? WashiXML.document(from: data),
                  let root = document.rootElement() else { continue }
            if optionSaysFixedLayout(root) { return true }
        }
        return false
    }

    private static func optionSaysFixedLayout(_ element: XMLElement) -> Bool {
        if element.name?.lowercased() == "option",
           element.attr("name")?.lowercased() == "fixed-layout",
           (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
               .lowercased() == "true" {
            return true
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, optionSaysFixedLayout(child) {
                return true
            }
        }
        return false
    }

    /// マニフェストのフォールバック連鎖(指定した項目自身から始め、循環があれば
    /// そこで打ち切る。EPUB RS 3.3 §5.4)。
    ///
    /// The manifest fallback chain (starting with the item itself; cycles are
    /// broken there. EPUB RS 3.3 §5.4).
    public func fallbackChain(for item: ManifestItem) -> [ManifestItem] {
        Self.fallbackChain(for: item, package: package)
    }

    // 初期化中の索引構築も、公開 API と同じ循環・欠落時の打ち切り規則を使う。
    private static func fallbackChain(
        for item: ManifestItem, package: EPUBPackage
    ) -> [ManifestItem] {
        var chain: [ManifestItem] = [item]
        var seen: Set<String> = [item.id]
        var current = item
        while let fallbackID = current.fallback,
              let next = package.manifestByID[fallbackID],
              !seen.contains(fallbackID) {
            chain.append(next)
            seen.insert(fallbackID)
            current = next
        }
        return chain
    }

    /// cooViewer-oxr.16: spine 表示に使える Core Media Type と XHTML だけを
    /// fallback 解決の終端候補にする。未知形式は連鎖をさらに辿る。
    private static func isRenderableSpineItem(_ item: ManifestItem) -> Bool {
        let mediaType = EPUBMediaType.normalized(item.mediaType)
        return mediaType == EPUBMediaType.xhtml
            || EPUBMediaType.coreImageTypes.contains(mediaType)
    }

    /// cooViewer-oxr.16: 循環を打ち切りつつ、実在性も含めて fallback を解決する。
    private static func resolvedSpineResource(
        for item: ManifestItem, package: EPUBPackage, packagePath: String,
        reader: any ContainerReader
    ) -> (item: ManifestItem, path: String)? {
        var current: ManifestItem? = item
        var seen: Set<String> = []
        while let candidate = current, seen.insert(candidate.id).inserted {
            if let path = ContainerPath.resolve(
                base: packagePath, href: candidate.href),
               isRenderableSpineItem(candidate), reader.exists(path) {
                return (candidate, path)
            }
            current = candidate.fallback.flatMap { package.manifestByID[$0] }
        }
        return nil
    }

    // MARK: - 基本情報

    public var metadata: EPUBMetadata { package.metadata }
    public var isFixedLayout: Bool { package.isFixedLayout }

    /// コンテナ内の、ディレクトリを除く全リソースのパス。順序は不定。索引作成、
    /// 抽出ツール、本の同梱内容の監査に使える。各リソースは ``resource(at:)`` で読む。
    ///
    /// Every non-directory resource path in the container, in no particular
    /// order. Useful for indexing, extraction tools, or auditing what a book
    /// ships. Read individual resources with ``resource(at:)``.
    public var resourcePaths: [String] { container.reader.allPaths }
    public var readingDirection: PageProgressionDirection {
        package.readingDirection
    }

    // MARK: - DRM

    /// spine のコンテンツ文書が未知のアルゴリズムで暗号化されている場合に true。
    /// Washi では開けない、本来の DRM による保護を表す。未知の暗号化を使うのが
    /// フォントなどの補助リソースだけなら、本は開ける(そのフォントなしで描画を
    /// 続ける。EPUB 3.3 OCF §4.4.2 で認められている)。
    ///
    /// True when a spine content document is encrypted with an unknown
    /// algorithm — genuine DRM protection that Washi cannot open.
    /// If only auxiliary resources (fonts, etc.) use unknown encryption the
    /// book is still openable (rendering continues without that font;
    /// permitted by EPUB 3.3 OCF §4.4.2).
    public var isDRMProtected: Bool {
        guard !encryption.unknownEncryptedResources.isEmpty else { return false }
        let spinePaths = Set(readingOrder.map(\.containerPath))
        return encryption.unknownEncryptedResources.keys
            .contains { spinePaths.contains($0) }
    }

    /// META-INF 内の特徴的なファイルから推定した DRM 方式。
    /// DRM で保護されていなければ nil。
    ///
    /// Best-guess DRM scheme (detected from fingerprint files under META-INF); nil when not DRM-protected.
    public var drmSchemeName: String? {
        // Honor the contract ("nil when not DRM-protected") for every branch: a
        // stray META-INF/sinf.xml or license.lcpl in a repackaged, non-encrypted
        // EPUB must not report DRM (cooViewer-2hp). Adobe ADEPT already gated on
        // isDRMProtected; lift the gate to the top so LCP/FairPlay share it.
        guard isDRMProtected else { return nil }
        let reader = container.reader
        if reader.exists("META-INF/license.lcpl") { return "Readium LCP" }
        if reader.exists("META-INF/sinf.xml") { return "Apple FairPlay" }
        if reader.exists("META-INF/rights.xml") { return "Adobe ADEPT" }
        return "Unknown DRM"
    }

    // MARK: - リソース

    /// コンテナ内パスでリソースを読み取り、フォントの難読化は透過的に解除する。
    /// 未知の暗号化が施されたリソースでは drmProtected を投げる。
    ///
    /// Reads a resource by its container path, transparently reversing font
    /// obfuscation. Throws drmProtected for a resource under unknown encryption.
    public func resource(at containerPath: String) throws -> (data: Data, mediaType: String) {
        // コンテナ内パスはデコード済みが正規形。二重デコードしない(sanitize)
        let path = ContainerPath.sanitize(containerPath)
        if let algorithm = encryption.unknownEncryptedResources[path] {
            throw EPUBError.drmProtected(scheme: algorithm)
        }
        var data = try container.reader.read(path)
        if let algorithm = encryption.obfuscatedResources[path] {
            data = deobfuscatedFont(data, algorithm: algorithm)
        }
        let mediaType = manifestByPath[path]?.mediaType
            ?? EPUBMediaType.guessed(fromPath: path)
        return (data, mediaType)
    }

    /// 難読化解除に使う識別子の選択。IDPF は unique-identifier そのもの。
    /// Adobe は「UUID 形の dc:identifier」を鍵にするツールが実在するため、
    /// unique-identifier が UUID 形でなければ他の識別子から UUID 形を探す
    /// (readium-js #153 の実運用知見)
    /// 難読化を解いたうえで、結果がフォントとして読めることを確かめる。
    /// encryption.xml の宣言は無条件には信じられない: Sigil や calibre の
    /// 編集で dc:identifier が差し替わった本、難読化していないのに宣言だけ
    /// 残った本があり、そのまま XOR するとフォントが壊れて WebKit が黙って
    /// 代替フォントへ落ちる(縦書き専用フォントや外字で字形が消える)。
    /// 宣言された識別子群を順に試し、どれも通らなければ素のデータを見る。
    /// 見つからなければ従来どおり最初の候補の結果を返す(cooViewer-oxr.46 C47)。
    private func deobfuscatedFont(
        _ data: Data, algorithm: EPUBEncryptionInfo.ObfuscationAlgorithm) -> Data {
        var fallback: Data?
        for identifier in obfuscationIdentifierCandidates(for: algorithm) {
            let candidate = FontDeobfuscator.deobfuscate(
                data, algorithm: algorithm, uniqueIdentifier: identifier)
            if FontDeobfuscator.looksLikeFont(candidate) { return candidate }
            if fallback == nil { fallback = candidate }
        }
        // 宣言だけ残っていて実際には難読化されていない本の救済。
        if FontDeobfuscator.looksLikeFont(data) { return data }
        return fallback ?? data
    }

    /// 難読化解除に使う識別子の候補(先頭が従来の選択)。
    private func obfuscationIdentifierCandidates(
        for algorithm: EPUBEncryptionInfo.ObfuscationAlgorithm) -> [String] {
        var candidates: [String] = []
        if let primary = obfuscationIdentifier(for: algorithm) {
            candidates.append(primary)
        }
        for identifier in metadata.identifiers.map(\.value)
        where !candidates.contains(identifier) {
            candidates.append(identifier)
        }
        return candidates
    }

    private func obfuscationIdentifier(
        for algorithm: EPUBEncryptionInfo.ObfuscationAlgorithm) -> String? {
        switch algorithm {
        case .idpf:
            return metadata.uniqueIdentifier
        case .adobe:
            if let uid = metadata.uniqueIdentifier,
               FontDeobfuscator.adobeKey(uniqueIdentifier: uid) != nil {
                return uid
            }
            return metadata.identifiers.map(\.value)
                .first { FontDeobfuscator.adobeKey(uniqueIdentifier: $0) != nil }
                ?? metadata.uniqueIdentifier
        }
    }

    /// 基準パスと相対 href からリソースを読み取る(ナビゲーション項目の解決など)。
    ///
    /// Reads a resource from a base path plus a relative href (e.g. resolving navigation items).
    public func resource(relativeTo basePath: String,
                         href: String) throws -> (data: Data, mediaType: String) {
        guard let path = ContainerPath.resolve(base: basePath, href: href) else {
            throw EPUBError.resourceNotFound(href)
        }
        return try resource(at: path)
    }

    /// 基準パスからの相対 href を、コンテナ内パスへ解決する。
    ///
    /// Resolves an href (relative to a base path) into a container path.
    public func containerPath(forHref href: String,
                              relativeTo basePath: String) -> String? {
        ContainerPath.resolve(base: basePath, href: href)
    }

    /// コンテナ内パスが存在するかを確認する。
    ///
    /// Checks whether a container path exists.
    public func resourceExists(at containerPath: String) -> Bool {
        container.reader.exists(ContainerPath.sanitize(containerPath))
    }
}
