import Foundation
import XCTest

/// WebKit の失敗を CI ではテスト失敗、ローカルでは環境依存のスキップとして扱う。
func failOrSkipWebKitTest(
    _ reason: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if ProcessInfo.processInfo.environment["CI"] != nil {
        XCTFail(reason, file: file, line: line)
    } else {
        throw XCTSkip(reason, file: file, line: line)
    }
}
