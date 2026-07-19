import XCTest
@testable import LassoConductorCore

final class HotkeyRegistrationLifecycleTests: XCTestCase {
    func testEditingSuspendsTheGlobalRegistrationAndSameChordMustBeReinstalled() {
        var lifecycle = HotkeyRegistrationLifecycle(hasRegistration: true)

        XCTAssertTrue(lifecycle.beginEditing())
        XCTAssertFalse(lifecycle.hasRegistration)
        XCTAssertTrue(lifecycle.needsInstallation(candidate: .defaultCapture,
                                                   active: .defaultCapture))

        XCTAssertTrue(lifecycle.endEditingNeedsRestore())
        lifecycle.didInstall()
        XCTAssertTrue(lifecycle.hasRegistration)
    }

    func testCancellingShortcutEditingRestoresThePreviousRegistration() {
        var lifecycle = HotkeyRegistrationLifecycle(hasRegistration: true)

        XCTAssertTrue(lifecycle.beginEditing())
        XCTAssertTrue(lifecycle.endEditingNeedsRestore())
    }

    func testInstallationWaitsUntilEveryRecorderHasFinished() {
        var lifecycle = HotkeyRegistrationLifecycle(hasRegistration: true)

        XCTAssertTrue(lifecycle.beginEditing())
        XCTAssertFalse(lifecycle.beginEditing())
        XCTAssertTrue(lifecycle.isEditing)
        XCTAssertFalse(lifecycle.installationAllowed)

        XCTAssertFalse(lifecycle.endEditingNeedsRestore())
        XCTAssertTrue(lifecycle.isEditing)
        XCTAssertTrue(lifecycle.installationAllowed)

        XCTAssertTrue(lifecycle.endEditingNeedsRestore())
        XCTAssertFalse(lifecycle.isEditing)
        XCTAssertTrue(lifecycle.installationAllowed)
    }
}
