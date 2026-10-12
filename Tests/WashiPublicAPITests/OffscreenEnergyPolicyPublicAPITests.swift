import AppKit
import XCTest
import Washi

/// 利用側と同じ公開 API だけで、省エネ方針の既定値と任意加入が書けること。
@MainActor
final class OffscreenEnergyPolicyPublicAPITests: XCTestCase {
    func testReaderViewDefaultsToUnrestrictedAndAcceptsFollowSystem() {
        let view = EPUBReaderView(frame: .zero)
        XCTAssertEqual(view.offscreenEnergyPolicy, .unrestricted)

        view.offscreenEnergyPolicy = .followSystem
        XCTAssertEqual(view.offscreenEnergyPolicy, .followSystem)
        XCTAssertNotEqual(EPUBOffscreenEnergyPolicy.unrestricted, .followSystem)
        XCTAssertEqual(
            Set([EPUBOffscreenEnergyPolicy.unrestricted, .followSystem, .followSystem]).count, 2)
    }
}
