import Foundation
@testable import Washi
@testable import WashiCore

extension EPUBFixtures {
    /// cooViewer-oxr.46 C07: 1 つの SMIL が 2 つの XHTML を束ねる本。
    /// W3C の mol-support_xhtml-load と同じ形で、両方の spine 項目が
    /// 同じ SMIL を media-overlay に指す。音声は用意しない(無音経路)。
    static func multiDocumentMediaOverlayEntries() -> [(name: String, data: Data)] {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:multi-mo</dc:identifier>
                <dc:title>複数文書 SMIL</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"
                      media-overlay="smil"/>
                <item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"
                      media-overlay="smil"/>
                <item id="smil" href="text/all.smil" media-type="application/smil+xml"/>
              </manifest>
              <spine><itemref idref="a"/><itemref idref="b"/></spine>
            </package>
            """
        let smil = """
            <?xml version="1.0" encoding="UTF-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
              <body><seq>
                <par id="p0"><text src="a.xhtml#s0"/>
                  <audio src="missing.mp3" clipBegin="0s" clipEnd="1s"/></par>
                <par id="p1"><text src="a.xhtml#s1"/>
                  <audio src="missing.mp3" clipBegin="1s" clipEnd="2s"/></par>
                <par id="p2"><text src="b.xhtml#s0"/>
                  <audio src="missing.mp3" clipBegin="2s" clipEnd="3s"/></par>
                <par id="p3"><text src="b.xhtml#s1"/>
                  <audio src="missing.mp3" clipBegin="3s" clipEnd="4s"/></par>
              </seq></body>
            </smil>
            """
        func page(_ name: String) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
            + "<head><meta charset=\"UTF-8\"/></head><body>"
            + "<p id=\"s0\">\(name) の一文目。</p><p id=\"s1\">\(name) の二文目。</p>"
            + "</body></html>"
        }
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/a.xhtml", Data(page("A").utf8)),
            ("OEBPS/text/b.xhtml", Data(page("B").utf8)),
            ("OEBPS/text/all.smil", Data(smil.utf8)),
        ]
    }

    /// cooViewer-oxr.46 C08: 音声ファイルを持たないメディアオーバーレイ。
    /// par は音声が用意できないので「短い間ハイライトして次へ」の経路を通る。
    static func silentMediaOverlayEntries(parCount: Int = 4)
        -> [(name: String, data: Data)] {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:silent-mo</dc:identifier>
                <dc:title>Silent media overlay</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"
                      media-overlay="smil"/>
                <item id="smil" href="text/c.smil" media-type="application/smil+xml"/>
              </manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        var pars = ""
        var body = ""
        for index in 0..<parCount {
            pars += """
                <par id="p\(index)">
                  <text src="c.xhtml#s\(index)"/>
                  <audio src="missing.mp3" clipBegin="0s" clipEnd="1s"/>
                </par>
                """
            body += "<p id=\"s\(index)\">第 \(index) 文。</p>"
        }
        let smil = """
            <?xml version="1.0" encoding="UTF-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
              <body><seq>\(pars)</seq></body>
            </smil>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
            + "<head><meta charset=\"UTF-8\"/></head><body>\(body)</body></html>"
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/c.xhtml", Data(xhtml.utf8)),
            ("OEBPS/text/c.smil", Data(smil.utf8)),
        ]
    }
}
