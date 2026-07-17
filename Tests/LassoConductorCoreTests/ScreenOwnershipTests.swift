import XCTest
@testable import LassoConductorCore

final class ScreenOwnershipTests: XCTestCase {
    func testCrossDisplayGestureBelongsToScreenWithLargestOverlap() {
        let screens = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]

        let owner = ScreenOwnership.dominantScreenIndex(
            for: CGRect(x: 80, y: 20, width: 70, height: 40),
            screenFrames: screens)

        XCTAssertEqual(owner, 1)
    }
}
