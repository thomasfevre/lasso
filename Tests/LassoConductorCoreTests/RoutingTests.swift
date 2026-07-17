import XCTest
@testable import LassoConductorCore

// SPE-547 seam-2: Target Window selection and Provider decision against fixture
// window z-order lists, including overlap cases.
final class RoutingTests: XCTestCase {
    private func window(_ id: Int, _ frame: CGRect, _ bundle: String?, z: Int) -> WindowInfo {
        WindowInfo(windowID: id, frame: frame, bundleIdentifier: bundle, appName: bundle, zOrder: z)
    }

    func testPicksTopmostWindowAtPoint() {
        // Two overlapping windows cover the Gesture centre; the frontmost (z=0)
        // wins even though the other is also under the point.
        let front = window(1, CGRect(x: 0, y: 0, width: 200, height: 200), "com.apple.Terminal", z: 0)
        let back = window(2, CGRect(x: 0, y: 0, width: 400, height: 400), "com.apple.Safari", z: 1)
        let decision = GestureRouter.route(
            gestureBBox: CGRect(x: 50, y: 50, width: 20, height: 20),
            windows: [back, front])   // deliberately out of z-order in the array
        XCTAssertEqual(decision.targetWindow?.windowID, 1)
        XCTAssertEqual(decision.provider, .screen)
    }

    func testOverlapDisambiguatedByLocationNotFocus() {
        // The Gesture sits only over the back-in-array Safari window's exclusive
        // region; the Terminal window does not cover the point, so Safari wins
        // and routes to web — regardless of which is "frontmost" overall.
        let terminal = window(1, CGRect(x: 0, y: 0, width: 100, height: 100), "com.apple.Terminal", z: 0)
        let safari = window(2, CGRect(x: 300, y: 300, width: 200, height: 200), "com.apple.Safari", z: 1)
        let decision = GestureRouter.route(
            gestureBBox: CGRect(x: 350, y: 350, width: 40, height: 40),
            windows: [terminal, safari])
        XCTAssertEqual(decision.targetWindow?.windowID, 2)
        XCTAssertEqual(decision.provider, .web)
    }

    func testBrowserRoutesToWebOtherRoutesToScreen() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let bbox = CGRect(x: 40, y: 40, width: 10, height: 10)
        for id in BrowserCatalog.defaultBundleIDs {
            let d = GestureRouter.route(gestureBBox: bbox, windows: [window(1, frame, id, z: 0)])
            XCTAssertEqual(d.provider, .web, "\(id) should route to web")
        }
        let nonBrowser = GestureRouter.route(
            gestureBBox: bbox, windows: [window(1, frame, "com.apple.dt.Xcode", z: 0)])
        XCTAssertEqual(nonBrowser.provider, .screen)
    }

    func testNoWindowUnderPointFallsBackToScreen() {
        let d = GestureRouter.route(
            gestureBBox: CGRect(x: 900, y: 900, width: 10, height: 10),
            windows: [window(1, CGRect(x: 0, y: 0, width: 100, height: 100), "com.apple.Safari", z: 0)])
        XCTAssertNil(d.targetWindow)
        XCTAssertEqual(d.provider, .screen)
    }

    func testNilBundleIdentifierIsNotABrowser() {
        XCTAssertFalse(BrowserCatalog.isBrowser(bundleIdentifier: nil))
        let d = GestureRouter.route(
            gestureBBox: CGRect(x: 10, y: 10, width: 5, height: 5),
            windows: [window(1, CGRect(x: 0, y: 0, width: 50, height: 50), nil, z: 0)])
        XCTAssertEqual(d.provider, .screen)
    }

    func testClipToTargetWindow() {
        let win = window(1, CGRect(x: 100, y: 100, width: 200, height: 200), "com.apple.Safari", z: 0)
        // A Gesture straddling the window's left edge clips to the overlap.
        let clipped = GestureRouter.clip(
            gestureBBox: CGRect(x: 50, y: 150, width: 100, height: 50), to: win)
        XCTAssertEqual(clipped, CGRect(x: 100, y: 150, width: 50, height: 50))
    }

    func testClipReturnsNilWhenOutsideWindow() {
        let win = window(1, CGRect(x: 0, y: 0, width: 100, height: 100), "com.apple.Safari", z: 0)
        XCTAssertNil(GestureRouter.clip(
            gestureBBox: CGRect(x: 200, y: 200, width: 10, height: 10), to: win))
    }
}
