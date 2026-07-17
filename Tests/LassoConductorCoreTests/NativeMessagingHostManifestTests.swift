import XCTest
@testable import LassoConductorCore

final class NativeMessagingHostManifestTests: XCTestCase {
    func testManifestUsesTheStableExtensionOriginAndSuppliedHostPath() throws {
        let data = try NativeMessagingHostManifest.data(
            executablePath: "/Applications/Lasso.app/Contents/MacOS/lasso-relay-host")
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(manifest["name"] as? String, "xyz.allez.lasso.host")
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertEqual(manifest["path"] as? String,
                       "/Applications/Lasso.app/Contents/MacOS/lasso-relay-host")
        XCTAssertEqual(manifest["allowed_origins"] as? [String],
                       ["chrome-extension://onhdnknhpacnkhanhnhgnfgofebpkcmn/"])
    }
}
