import XCTest
@testable import Washi
@testable import WashiCore

/// META-INF/encryption.xml と rights.xml からの DRM 検出と方式名
final class EncryptionDetectionTests: XCTestCase {
    func testDRMDetection() throws {
        let encryptionXML = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        var entries = EPUBFixtures.verticalNovelEntries()
        entries.append(("META-INF/encryption.xml", Data(encryptionXML.utf8)))
        entries.append(("META-INF/rights.xml",
                        Data("<rights xmlns=\"http://ns.adobe.com/adept\"/>".utf8)))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/drm.epub"))
        XCTAssertTrue(publication.isDRMProtected)
        XCTAssertEqual(publication.drmSchemeName, "Adobe ADEPT")
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/text/ch1.xhtml")) {
            guard case EPUBError.drmProtected = $0 else {
                return XCTFail("drmProtected であるべき: \($0)")
            }
        }
    }

    /// cooViewer-oxr.17: 指紋ファイルのない未知方式も公開表示は英語に統一する。
    func testUnknownDRMNameIsEnglish() throws {
        let encryptionXML = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="urn:example:unknown-drm"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        var entries = EPUBFixtures.verticalNovelEntries()
        entries.append(("META-INF/encryption.xml", Data(encryptionXML.utf8)))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/unknown-drm.epub"))
        XCTAssertTrue(publication.isDRMProtected)
        XCTAssertEqual(publication.drmSchemeName, "Unknown DRM")
    }
}
