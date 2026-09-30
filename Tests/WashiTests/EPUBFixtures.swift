import Foundation
import XCTest
@testable import Washi
@testable import WashiCore

/// EPUB フィクスチャ(縦組み小説・FXL 漫画)の構成ファイル生成
enum EPUBFixtures {
    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    /// 縦組み小説(電書協ガイド風): rtl・vertical-rl・ルビ入り
    static let verticalNovelOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="ja">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
            <dc:title id="title">吾輩は猫である</dc:title>
            <meta refines="#title" property="title-type">main</meta>
            <meta refines="#title" property="file-as">わがはいはねこである</meta>
            <dc:creator id="creator">夏目漱石</dc:creator>
            <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>
            <meta refines="#creator" property="file-as">なつめそうせき</meta>
            <dc:language>ja</dc:language>
            <dc:publisher>青空文庫</dc:publisher>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
            <meta property="belongs-to-collection" id="series">漱石全集</meta>
            <meta refines="#series" property="collection-type">series</meta>
            <meta refines="#series" property="group-position">1</meta>
            <meta property="schema:accessMode">textual</meta>
            <meta property="schema:accessMode">visual</meta>
            <meta property="schema:accessModeSufficient">textual,visual</meta>
            <meta property="schema:accessibilityFeature">structuralNavigation</meta>
            <meta property="schema:accessibilityHazard">noFlashingHazard</meta>
            <meta property="schema:accessibilitySummary">目次による構造ナビゲーションに対応。</meta>
            <meta property="dcterms:conformsTo">http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-aa</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="style" href="style.css" media-type="text/css"/>
            <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="colophon" href="text/colophon.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine page-progression-direction="rtl" toc="ncx">
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
            <itemref idref="colophon" linear="no"/>
          </spine>
        </package>
        """

    static let navXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
        <head><title>目次</title></head>
        <body>
          <nav epub:type="toc">
            <h1>目次</h1>
            <ol>
              <li><a href="text/ch1.xhtml">第一章</a>
                <ol><li><a href="text/ch1.xhtml#sec1">一の一</a></li></ol>
              </li>
              <li><a href="text/ch2.xhtml">第二章</a></li>
            </ol>
          </nav>
          <nav epub:type="landmarks" hidden="">
            <ol>
              <li><a epub:type="bodymatter" href="text/ch1.xhtml">本文</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """

    static let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="urn:uuid:12345678-1234-1234-1234-123456789abc"/></head>
          <docTitle><text>吾輩は猫である</text></docTitle>
          <navMap>
            <navPoint id="p1" playOrder="1">
              <navLabel><text>第一章</text></navLabel>
              <content src="text/ch1.xhtml"/>
              <navPoint id="p1-1" playOrder="2">
                <navLabel><text>一の一</text></navLabel>
                <content src="text/ch1.xhtml#sec1"/>
              </navPoint>
            </navPoint>
            <navPoint id="p2" playOrder="3">
              <navLabel><text>第二章</text></navLabel>
              <content src="text/ch2.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """

    static func chapterXHTML(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">
        <head><title>\(title)</title>
        <link rel="stylesheet" type="text/css" href="../style.css"/></head>
        <body class="vrtl">\(body)</body>
        </html>
        """
    }

    static let verticalCSS = """
        @charset "UTF-8";
        html { writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; }
        body { font-family: "Hiragino Mincho ProN", serif; }
        """

    /// 1x1 PNG(最小の正当な PNG)
    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg==")!

    /// 縦組み小説 EPUB 一式(パス → データ)
    static func verticalNovelEntries() -> [(name: String, data: Data)] {
        [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(verticalNovelOPF.utf8)),
            ("OEBPS/nav.xhtml", Data(navXHTML.utf8)),
            ("OEBPS/toc.ncx", Data(ncx.utf8)),
            ("OEBPS/style.css", Data(verticalCSS.utf8)),
            ("OEBPS/images/cover.png", tinyPNG),
            ("OEBPS/text/ch1.xhtml", Data(chapterXHTML(
                title: "第一章",
                body: """
                <h1>第一章</h1><p id="sec1"><ruby>吾輩<rt>わがはい</rt></ruby>は\
                <ruby>猫<rt>ねこ</rt></ruby>である。名前はまだ無い。</p>
                """).utf8)),
            ("OEBPS/text/ch2.xhtml", Data(chapterXHTML(
                title: "第二章", body: "<h1>第二章</h1><p>どこで生れたかとんと見当がつかぬ。</p>").utf8)),
            ("OEBPS/text/colophon.xhtml", Data(chapterXHTML(
                title: "奥付", body: "<p>奥付</p>").utf8)),
        ]
    }

    /// FXL 漫画(pre-paginated・rtl・page-spread 指定・単一画像ページ)
    static let fxlComicOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"
                 prefix="rend: http://www.idpf.org/vocab/rendition/#">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:87654321-4321-4321-4321-cba987654321</dc:identifier>
            <dc:title>テスト漫画 第1巻</dc:title>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-02-02T00:00:00Z</meta>
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rend:spread">landscape</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="p1" href="p001.xhtml" media-type="application/xhtml+xml"/>
            <item id="p2" href="p002.xhtml" media-type="application/xhtml+xml"/>
            <item id="p3" href="p003.xhtml" media-type="application/xhtml+xml"/>
            <item id="i1" href="images/p001.png" media-type="image/png" properties="cover-image"/>
            <item id="i2" href="images/p002.png" media-type="image/png"/>
            <item id="i3" href="images/p003.png" media-type="image/png"/>
          </manifest>
          <spine page-progression-direction="rtl">
            <itemref idref="p1" properties="rendition:page-spread-center"/>
            <itemref idref="p2" properties="rendition:page-spread-left"/>
            <itemref idref="p3" properties="page-spread-right"/>
          </spine>
        </package>
        """

    static func fxlPageXHTML(image: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>page</title>
        <meta name="viewport" content="width=1200, height=1920"/></head>
        <body><div><img src="images/\(image)" alt=""/></div></body>
        </html>
        """
    }

    static let fxlNavXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc"><ol><li><a href="p001.xhtml">表紙</a></li></ol></nav></body>
        </html>
        """

    static func fxlComicEntries() -> [(name: String, data: Data)] {
        [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(fxlComicOPF.utf8)),
            ("OEBPS/nav.xhtml", Data(fxlNavXHTML.utf8)),
            ("OEBPS/p001.xhtml", Data(fxlPageXHTML(image: "p001.png").utf8)),
            ("OEBPS/p002.xhtml", Data(fxlPageXHTML(image: "p002.png").utf8)),
            ("OEBPS/p003.xhtml", Data(fxlPageXHTML(image: "p003.png").utf8)),
            ("OEBPS/images/p001.png", tinyPNG),
            ("OEBPS/images/p002.png", tinyPNG),
            ("OEBPS/images/p003.png", tinyPNG),
        ]
    }

    /// 単一 spine の最小 EPUB(見開きで奇数総ページになる本文。cooViewer-97e 用)
    static func singleSpineEntries(bodyHTML: String) -> [(name: String, data: Data)] {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:single-spine</dc:identifier>
                <dc:title>Single spine</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-02T00:00:00Z</meta>
              </metadata>
              <manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
            + "<head><meta charset=\"UTF-8\"/><style>body{font-size:20px;line-height:1.8}</style></head>"
            + "<body>\(bodyHTML)</body></html>"
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/c.xhtml", Data(xhtml.utf8)),
        ]
    }

    // cooViewer-oxr.3 / cooViewer-oxr.6: 2:3 の実画像を持つ単一 spine。
    // 12×18 PNG の自然寸法で、属性に依存しない img の比率計算も検証する。
    static func imagePageEntries(bodyHTML: String) -> [(name: String, data: Data)] {
        var entries = singleSpineEntries(bodyHTML: bodyHTML)
        let index = entries.firstIndex { $0.name == "OEBPS/package.opf" }!
        let opf = String(decoding: entries[index].data, as: UTF8.self)
            .replacingOccurrences(of: "</manifest>", with:
                "<item id=\"image\" href=\"images/page.png\" media-type=\"image/png\"/></manifest>")
        entries[index].data = Data(opf.utf8)
        entries.append(("OEBPS/images/page.png", Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAwAAAASCAIAAADgy6hbAAAAFUlEQVR4nGMwStlCEDGMKhpVRG9FANnBFoCfl0IfAAAAAElFTkSuQmCC")!))
        return entries
    }

    // cooViewer-oxr.6: 同じ XHTML を JS と Core の両側で判定する。
    static var imagePageDetectionCases: [(name: String, body: String, expected: Bool)] {
        let img = "<img src=\"../images/page.png\"/>"
        return [
            ("画像のみ", img, true),
            ("style と非表示代替文", "<style>body { margin: 0; }</style>"
                + "<p style=\"display:none\"><span>表紙の説明</span></p>" + img, true),
            ("script", "<script>var cover = '表紙';</script>" + img, true),
            ("hidden", "<div hidden=\"hidden\"><span>代替文</span></div>" + img, true),
            ("SVG メタデータ", """
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
                     width="100%" height="100%" viewBox="0 0 1200 1800">
                    <title>表紙</title><desc>表紙の説明</desc>
                    <image width="1200" height="1800" xlink:href="../images/page.png"/>
                </svg>
                """, true),
            ("同一画像のパネル複製", img + "<div hidden=\"hidden\">" + img + "</div>", true),
            ("可視の本文", img + "<p>本文</p>", false),
            ("異なる画像", img + "<img src=\"../images/other.png\"/>", false),
            ("src の欠落", img + "<img/>", false),
            ("画像なし", "<style>body { margin: 0; }</style>", false),
        ]
    }

    /// rendition:spread を宣言する単一 spine の長文リフロー EPUB
    static func reflowSpreadEntries(
        renditionSpread: RenditionSpread, bodyHTML: String
    ) -> [(name: String, data: Data)] {
        let rawSpread = renditionSpread.rawValue
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:reflow-spread-\(rawSpread)</dc:identifier>
                <dc:title>Reflow spread \(rawSpread)</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
                <meta property="rendition:spread">\(rawSpread)</meta>
              </metadata>
              <manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
            + "<head><meta charset=\"UTF-8\"/><style>"
            + "html{writing-mode:horizontal-tb}body{font-size:20px;line-height:1.8}"
            + "</style></head><body>\(bodyHTML)</body></html>"
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/c.xhtml", Data(xhtml.utf8)),
        ]
    }
}

// テストから EPUBPublication を組み立てる近道。deflate(method 8)で固め、
// displayURL は /tmp/<name>.epub にする(store のまま固めたい場合は method: 0 を渡す)
extension EPUBFixtures {
    static func publication(_ entries: [(name: String, data: Data)],
                            name: String = #function, method: UInt16 = 8) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(entries, method: method),
            displayURL: URL(fileURLWithPath: "/tmp/\(name).epub"))
    }

    /// 縦組み小説 EPUB
    static func verticalNovel(name: String = #function) throws -> EPUBPublication {
        try publication(verticalNovelEntries(), name: name)
    }

    /// FXL 漫画 EPUB
    static func fxlComic(name: String = #function) throws -> EPUBPublication {
        try publication(fxlComicEntries(), name: name)
    }

    /// 単一 spine の最小 EPUB
    static func singleSpine(bodyHTML: String, name: String = #function) throws -> EPUBPublication {
        try publication(singleSpineEntries(bodyHTML: bodyHTML), name: name)
    }

    /// `path` の項目の中の `target` を `replacement` に置き換えた entries を返す。
    /// 項目が無い・`target` が含まれない(フィクスチャが変わった)場合はテスト失敗にする
    static func replacing(_ entries: [(name: String, data: Data)], in path: String,
                          of target: String, with replacement: String,
                          file: StaticString = #filePath, line: UInt = #line) throws
        -> [(name: String, data: Data)]
    {
        var entries = entries
        let index = try XCTUnwrap(entries.firstIndex { $0.name == path },
                                  "フィクスチャに \(path) が無い", file: file, line: line)
        let source = String(decoding: entries[index].data, as: UTF8.self)
        XCTAssertTrue(source.contains(target),
                      "フィクスチャの \(path) に \(target) が無い", file: file, line: line)
        entries[index].data = Data(source.replacingOccurrences(of: target, with: replacement).utf8)
        return entries
    }
}
