import Foundation

/// OCF 抽象コンテナ(仕様 EPUB 3.3 OCF §3)。
/// ZIP(.epub)と展開済みフォルダの両方を同じ読み取り API で扱う。
/// パスは「/ 区切り・ルート相対・デコード済み」の正規形。
protocol ContainerReader: Sendable {
    func exists(_ path: String) -> Bool
    func read(_ path: String) throws -> Data
    /// コンテナ内の全ファイルパス(ディレクトリ除く)
    var allPaths: [String] { get }
}

/// ZIP(.epub ファイル)のコンテナ
struct ZipContainerReader: ContainerReader {
    let archive: ZipArchive

    var allPaths: [String] {
        archive.entries.filter { !$0.isDirectory }.map(\.name)
    }

    func exists(_ path: String) -> Bool { archive.contains(path) }

    func read(_ path: String) throws -> Data {
        do {
            return try archive.data(forEntry: path)
        } catch ZipError.entryNotFound {
            throw EPUBError.resourceNotFound(path)
        } catch let error as ZipError {
            // cooViewer-oxr.17: ZIP 実装の詳細型を ContainerReader 境界から
            // 漏らさず、呼び出し側がパスと英語の理由を一緒に報告できる形へ写す。
            throw EPUBError.containerReadFailed(
                path: path,
                reason: error.errorDescription ?? "Unknown ZIP read failure")
        }
    }
}

/// 展開済みフォルダのコンテナ(開発時・解凍済み配布物向け)
struct FolderContainerReader: ContainerReader {
    let rootURL: URL
    var readStrategy: EPUBReadStrategy = .mappedIfSafe

    var allPaths: [String] {
        let root = rootURL.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            // シンボリックリンクは列挙しない(コンテナ外の実体を「コンテナ内
            // リソース」として晒さない。read 側の実体検証と対)
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, values.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if full.hasPrefix(prefix) {
                paths.append(String(full.dropFirst(prefix.count)))
            }
        }
        return paths.sorted()
    }

    /// コンテナ外への脱出参照でないことの検証(フォルダ実装だけが実 FS に
    /// 触れるため、".." 成分・絶対パス・空を明示的に拒否する。
    /// normalize の同値比較では ".." が残った脱出パスを見逃す)
    private func isSafeContainerPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/")
        return !components.isEmpty
            && !components.contains("..") && !components.contains(".")
    }

    /// パス成分は安全でも、途中のシンボリックリンクが実体をコンテナ外へ
    /// 逃がしている場合を拒否する(~/.ssh 等をスキームハンドラ経由で
    /// 読ませない)。実体パスを解決してルート配下であることを検証する
    private func isInsideContainer(_ url: URL) -> Bool {
        let resolvedRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved == resolvedRoot
            || resolved.hasPrefix(resolvedRoot.hasSuffix("/")
                ? resolvedRoot : resolvedRoot + "/")
    }

    func exists(_ path: String) -> Bool {
        guard isSafeContainerPath(path) else { return false }
        var isDirectory: ObjCBool = false
        let url = rootURL.appendingPathComponent(path)
        return isInsideContainer(url)
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    func read(_ path: String) throws -> Data {
        guard isSafeContainerPath(path) else {
            throw EPUBError.resourceNotFound(path)
        }
        let url = rootURL.appendingPathComponent(path)
        guard isInsideContainer(url) else {
            throw EPUBError.resourceNotFound(path)
        }
        do {
            return try Data(contentsOf: url, options: readStrategy.dataOptions)
        } catch {
            throw EPUBError.resourceNotFound(path)
        }
    }
}

/// cooViewer-oxr.46 C44: 自炊層に多い梱包ミスを、厳密な解決が外れたときだけ
/// 救済する包み。ルート接頭辞(フォルダごと圧縮)・大文字小文字違いの一意一致を
/// 扱う。正しい本では最初の完全一致で抜けるので、経路も費用も変わらない。
struct RescuingContainerReader: ContainerReader {
    let base: any ContainerReader
    /// 全エントリが共有する余分な先頭ディレクトリ("book/" 等。無ければ空)
    let rootPrefix: String
    /// 小文字化したパス → 実際のパス(一意に定まるものだけ)
    let caseInsensitiveIndex: [String: String]

    init(base: any ContainerReader) {
        self.base = base
        let paths = base.allPaths
        // フォルダごと ZIP 圧縮すると全エントリが "書名/" の下に入る。
        // container.xml がその形でだけ見つかるなら、その接頭辞を剥がす。
        var prefix = ""
        if !paths.contains("META-INF/container.xml") {
            let marker = "/META-INF/container.xml"
            let candidates = paths.filter { $0.hasSuffix(marker) }
            if candidates.count == 1, let only = candidates.first {
                prefix = String(only.dropLast(marker.count - 1))
            }
        }
        self.rootPrefix = prefix
        // OPF の href は大文字小文字が食い違うことがある。一意に定まる場合だけ
        // 救済し、複数候補があるときは曖昧なので手を出さない。
        var lowered: [String: [String]] = [:]
        for path in paths {
            lowered[path.lowercased(), default: []].append(path)
        }
        self.caseInsensitiveIndex = lowered.compactMapValues {
            $0.count == 1 ? $0[0] : nil
        }
    }

    var allPaths: [String] {
        guard !rootPrefix.isEmpty else { return base.allPaths }
        return base.allPaths.compactMap {
            $0.hasPrefix(rootPrefix) ? String($0.dropFirst(rootPrefix.count)) : nil
        }
    }

    /// 厳密な解決に失敗したときだけ試す候補(順に評価する)
    private func resolve(_ path: String) -> String? {
        if base.exists(path) { return path }
        if !rootPrefix.isEmpty, base.exists(rootPrefix + path) {
            return rootPrefix + path
        }
        if let match = caseInsensitiveIndex[path.lowercased()] { return match }
        if !rootPrefix.isEmpty,
           let match = caseInsensitiveIndex[(rootPrefix + path).lowercased()] {
            return match
        }
        return nil
    }

    func exists(_ path: String) -> Bool { resolve(path) != nil }

    func read(_ path: String) throws -> Data {
        guard let resolved = resolve(path) else {
            throw EPUBError.resourceNotFound(path)
        }
        return try base.read(resolved)
    }
}
