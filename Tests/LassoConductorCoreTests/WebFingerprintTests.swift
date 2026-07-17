import XCTest
import LassoCore
@testable import LassoConductorCore

// SPE-549: coordinate translation and Fingerprint decoding (the Conductor half).
final class WebFingerprintTests: XCTestCase {
    func testTopLeftFlip() {
        // A 100-tall screen; a 20-tall gesture whose bottom-left y is 30 sits with
        // its top at y=50, so top-left y = 100 - 50 = 50.
        let flipped = ScreenSpace.topLeftRect(
            fromBottomLeft: CGRect(x: 10, y: 30, width: 40, height: 20), primaryHeight: 100)
        XCTAssertEqual(flipped, CGRect(x: 10, y: 50, width: 40, height: 20))
    }

    // SPE-561: the AppKit↔Quartz flip about the primary height is the correct
    // GLOBAL transform, not a primary-only one. These fixtures prove it holds for
    // secondary displays positioned above/left of primary (negative-origin global
    // coordinates), which is where a "primary-only" bug would show up.
    func testFlipIsSelfInverse() {
        let h: CGFloat = 1080
        for y in [-1200, -1, 0, 540, 1080, 2200] as [CGFloat] {
            XCTAssertEqual(ScreenSpace.flipY(ScreenSpace.flipY(y, primaryHeight: h), primaryHeight: h), y)
        }
    }

    func testPointOnDisplayAbovePrimaryFlipsToNegativeQuartzY() {
        // Primary is 1080 tall. A secondary display sits directly above it, so its
        // AppKit y runs 1080…2280. A point near the top of the secondary display
        // (AppKit y = 2280) is above the primary's top edge in Quartz → y = -1200.
        let p = ScreenSpace.topLeftPoint(fromBottomLeft: CGPoint(x: 300, y: 2280), primaryHeight: 1080)
        XCTAssertEqual(p, CGPoint(x: 300, y: -1200))
    }

    func testRectOnDisplayLeftOfPrimaryKeepsNegativeXAndFlipsY() {
        // Secondary display to the LEFT of primary: negative AppKit x. x is a pure
        // translation (unchanged by the flip); only y flips about primaryHeight.
        let flipped = ScreenSpace.topLeftRect(
            fromBottomLeft: CGRect(x: -1600, y: 200, width: 100, height: 50), primaryHeight: 900)
        // top edge in AppKit is y+height = 250 → Quartz y = 900 - 250 = 650.
        XCTAssertEqual(flipped, CGRect(x: -1600, y: 650, width: 100, height: 50))
    }

    func testRectFullyAbovePrimaryHasNegativeQuartzY() {
        // A gesture entirely on a taller secondary display above primary: its top
        // edge (AppKit maxY = 2000) maps to a negative Quartz y.
        let flipped = ScreenSpace.topLeftRect(
            fromBottomLeft: CGRect(x: 0, y: 1400, width: 40, height: 600), primaryHeight: 1080)
        XCTAssertEqual(flipped, CGRect(x: 0, y: -920, width: 40, height: 600))
    }

    func testDecodeFullFingerprint() {
        let fp = WebFingerprint.decode([
            "selector": "#save",
            "role": "button",
            "text": "Save",
            "nearbyText": "Save your changes",
            "componentName": "SaveButton",
            "bbox": ["x": 12.0, "y": 34.0, "width": 80.0, "height": 24.0],
        ])
        XCTAssertEqual(fp?.selector, "#save")
        XCTAssertEqual(fp?.role, "button")
        XCTAssertEqual(fp?.componentName, "SaveButton")
        XCTAssertEqual(fp?.bbox, BBox(x: 12, y: 34, width: 80, height: 24))
    }

    func testDecodeWithoutComponentName() {
        // No React DevTools hook: componentName absent, still a valid Fingerprint.
        let fp = WebFingerprint.decode([
            "selector": "div.card > button:nth-of-type(2)",
            "role": "button",
            "text": "Buy",
        ])
        XCTAssertNotNil(fp)
        XCTAssertNil(fp?.componentName)
        XCTAssertNil(fp?.bbox)
    }

    func testDecodeRejectsMissingSelector() {
        XCTAssertNil(WebFingerprint.decode(["role": "button", "text": "x"]))
        XCTAssertNil(WebFingerprint.decode(["selector": "   "]))
    }

    func testDecodeToleratesIntCoordinates() {
        let fp = WebFingerprint.decode([
            "selector": "#a",
            "bbox": ["x": 1, "y": 2, "width": 3, "height": 4],
        ])
        XCTAssertEqual(fp?.bbox, BBox(x: 1, y: 2, width: 3, height: 4))
    }
}
