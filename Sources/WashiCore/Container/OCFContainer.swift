import Foundation

/// OCF コンテナのルート構成(mimetype / META-INF/container.xml)を検証・解析する
struct OCFContainer: Sendable {
    let reader: any ContainerReader
    /// container.xml の rootfile(先頭がデフォルトのパッケージ文書。OCF §3.5.2.1)
    let packageDocumentPaths: [String]

    init(reader: any ContainerReader) throws {
        self.reader = reader

        // mimetype はあれば検証する(なくても開く: RS には寛容さが許される。
        // ZIP 圧縮済みでも中身が正しければ受け入れる)
        if reader.exists("mimetype") {
            let mimetype = (try? reader.read("mimetype")).flatMap {
                String(data: $0, encoding: .utf8)
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mimetype, mimetype != EPUBMediaType.epub {
                throw EPUBError.notAnEPUB("mimetype が \(mimetype)")
            }
        }

        let containerXMLPath = "META-INF/container.xml"
        guard reader.exists(containerXMLPath) else {
            throw EPUBError.notAnEPUB("META-INF/container.xml がない")
        }
        let document = try WashiXML.document(from: reader.read(containerXMLPath))
        guard let root = document.rootElement() else {
            throw EPUBError.malformed(containerXMLPath)
        }
        let rootfiles = root
            .wsFirst("rootfiles", ns: XMLNamespace.container)?
            .wsChildren("rootfile", ns: XMLNamespace.container) ?? []
        let paths = rootfiles.compactMap { element -> String? in
            guard element.attr("media-type") == EPUBMediaType.opf
                    || element.attr("media-type") == nil else { return nil }
            return element.attr("full-path").map(ContainerPath.normalize)
        }
        guard !paths.isEmpty else {
            throw EPUBError.malformed("container.xml に rootfile がない")
        }
        self.packageDocumentPaths = paths
    }
}
