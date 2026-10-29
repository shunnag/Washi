import Foundation
import XCTest
@testable import WashiCore

final class NativeXMLAttributeTests: XCTestCase {
    func testAttributeStorageAndUnicodePathsArePreserved() throws {
        let href = "../画像/か\u{3099}く\u{3099}け\u{3099}/" + String(repeating: "章節", count: 20) + ".xhtml#位置"
        let xml = "<a xmlns:e='http://www.idpf.org/2007/ops' href='\(href)' e:type='bodymatter'/>"
        let root = try XCTUnwrap(WashiXML.document(from: Data(xml.utf8)).rootElement())
        let raw = try XCTUnwrap(root.attribute(forName: "href")?.stringValue)
        let native = try XCTUnwrap(root.attr("href"))
        XCTAssertTrue(native.isContiguousUTF8)
        XCTAssertEqual(Array(native.utf8), Array(raw.utf8))
        XCTAssertEqual(ContainerPath.resolve(base: "OPS/nav/index.xhtml", href: native),
                       ContainerPath.resolve(base: "OPS/nav/index.xhtml", href: raw))
        let type = try XCTUnwrap(root.attr("type", ns: XMLNamespace.epubOps, prefix: "e"))
        XCTAssertTrue(type.isContiguousUTF8)
        XCTAssertEqual(type, "bodymatter")
        XCTAssertNil(root.attr("missing"))
        XCTAssertNil(root.attr("missing", ns: XMLNamespace.epubOps, prefix: "e"))
    }

    func testUndeclaredPrefixAttributeRescueRemainsNative() throws {
        let root = XMLElement(name: "image")
        root.addAttribute(try XCTUnwrap(XMLNode.attribute(
            withName: "xlink:href", stringValue: "画像/表紙.png") as? XMLNode))
        let href = try XCTUnwrap(root.xlinkHref)
        XCTAssertEqual(href, "画像/表紙.png")
        XCTAssertTrue(href.isContiguousUTF8)
    }
}
