import XCTest
@testable import LassoHub

// SPE-550: the register snippet must advertise a correct binary path however
// the Hub was invoked.
final class BinaryPathResolverTests: XCTestCase {
    func testAbsolutePathUsedAsIs() {
        let r = BinaryPathResolver.resolve(arg0: "/opt/lasso/lasso-mcp", cwd: "/somewhere",
                                           pathEnv: nil, fileExists: { _ in false })
        XCTAssertEqual(r, "/opt/lasso/lasso-mcp")
    }

    func testRelativeWithSlashResolvedAgainstCwd() {
        let r = BinaryPathResolver.resolve(arg0: "build/lasso-mcp", cwd: "/work/proj",
                                           pathEnv: nil, fileExists: { _ in false })
        XCTAssertEqual(r, "/work/proj/build/lasso-mcp")
    }

    func testBareNameFoundOnPath() {
        let r = BinaryPathResolver.resolve(arg0: "lasso-mcp", cwd: "/work",
                                           pathEnv: "/usr/bin:/usr/local/bin",
                                           fileExists: { $0 == "/usr/local/bin/lasso-mcp" })
        XCTAssertEqual(r, "/usr/local/bin/lasso-mcp")
    }

    func testBareNameNotOnPathFallsBackToBareName() {
        let r = BinaryPathResolver.resolve(arg0: "lasso-mcp", cwd: "/work",
                                           pathEnv: "/usr/bin", fileExists: { _ in false })
        XCTAssertEqual(r, "lasso-mcp")
    }
}
