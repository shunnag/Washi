import XCTest
@testable import Washi
@testable import WashiCore

/// SMIL(メディアオーバーレイ)のクロック値と par の解析
final class SMILParserTests: XCTestCase {
    func testMediaOverlayParsing() throws {
        XCTAssertEqual(SMILParser.parseClockValue("12.5s"), 12.5)
        XCTAssertEqual(SMILParser.parseClockValue("1250ms"), 1.25)
        XCTAssertEqual(SMILParser.parseClockValue("1:02:03.5"), 3723.5)
        XCTAssertEqual(SMILParser.parseClockValue("02:03"), 123)
        // 不正なクロック値(NaN/Inf/負)は nil = 省略扱い。AVAudioPlayer への
        // 不正シーク・クリップ終端の恒偽化(ティッカー空回り)を防ぐ
        XCTAssertNil(SMILParser.parseClockValue("nans"))
        XCTAssertNil(SMILParser.parseClockValue("1e999s"))
        XCTAssertNil(SMILParser.parseClockValue("-5s"))
        XCTAssertNil(SMILParser.parseClockValue("-1:00"))
        XCTAssertNil(SMILParser.parseClockValue(""))
        let smil = """
        <?xml version="1.0"?>
        <smil xmlns="http://www.w3.org/ns/SMIL"
              xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
          <body>
            <seq>
              <par id="p1">
                <text src="ch1.xhtml#w1"/>
                <audio src="audio/ch1.m4a" clipBegin="0s" clipEnd="2.5s"/>
              </par>
              <par id="p2" epub:type="footnote">
                <text src="ch1.xhtml#w2"/>
                <audio src="audio/ch1.m4a" clipBegin="2.5s" clipEnd="5s"/>
              </par>
            </seq>
          </body>
        </smil>
        """
        let overlay = try SMILParser.parse(data: Data(smil.utf8),
                                           at: "OEBPS/ch1.smil")
        XCTAssertEqual(overlay.parallels.count, 2)
        XCTAssertEqual(overlay.parallels[0].textHref, "ch1.xhtml#w1")
        XCTAssertEqual(overlay.parallels[0].clipEnd, 2.5)
        XCTAssertEqual(overlay.parallels[1].epubType, "footnote")
    }
}
