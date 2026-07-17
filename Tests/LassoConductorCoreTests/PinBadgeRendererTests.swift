#if os(macOS)
import AppKit
import XCTest
@testable import LassoConductorCore
import LassoCore

final class PinBadgeRendererTests: XCTestCase {
    func testCenterConvertsTopLeftNormalizedMarkerIntoAppKitCoordinates() {
        let marker = Marker(index: 1, x: 0.25, y: 0.75)
        let imageRect = NSRect(x: 40, y: 20, width: 400, height: 200)

        let center = PinBadgeRenderer.center(for: marker, in: imageRect)

        XCTAssertEqual(center.x, 140, accuracy: 0.001)
        XCTAssertEqual(center.y, 70, accuracy: 0.001)
    }

    func testExportDiameterHasReadableMinimumAndScalesWithLargeImages() {
        XCTAssertEqual(PinBadgeRenderer.exportDiameter(for: NSSize(width: 120, height: 80)), 28)
        XCTAssertEqual(PinBadgeRenderer.exportDiameter(for: NSSize(width: 2_000, height: 1_000)), 50)
    }
}
#endif
