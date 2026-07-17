import XCTest
@testable import LassoConductorCore

// SPE-552: onboarding step progression.
final class OnboardingTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LassoOnboardingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testFreshStartAtPermissions() {
        let s = OnboardingState()
        XCTAssertEqual(s.currentStep, .permissions)
        XCTAssertFalse(s.isComplete)
    }

    func testScreenRecordingAloneClearsPermissions() {
        // Accessibility is optional and must not block progression.
        let s = OnboardingState(screenRecordingGranted: true)
        XCTAssertTrue(s.permissionsComplete)
        XCTAssertEqual(s.currentStep, .extensionPairing)
    }

    func testAccessibilityWithoutScreenRecordingStaysOnPermissions() {
        let s = OnboardingState(screenRecordingGranted: false, accessibilityGranted: true)
        XCTAssertEqual(s.currentStep, .permissions)
    }

    func testAdvancesToRegisterAfterPairing() {
        let s = OnboardingState(screenRecordingGranted: true, extensionPaired: true)
        XCTAssertEqual(s.currentStep, .registerAgents)
    }

    func testCompleteWhenAllSatisfied() {
        let s = OnboardingState(screenRecordingGranted: true, extensionPaired: true,
                                agentsAcknowledged: true)
        XCTAssertEqual(s.currentStep, .done)
        XCTAssertTrue(s.isComplete)
    }

    func testAcknowledgingAgentsBeforePairingDoesNotSkipPairing() {
        let s = OnboardingState(screenRecordingGranted: true, agentsAcknowledged: true)
        XCTAssertEqual(s.currentStep, .extensionPairing)
    }

    func testSkippingOptionalExtensionAdvancesToRegister() {
        // The extension is optional; skipping it moves the flow forward exactly
        // as pairing would.
        let s = OnboardingState(screenRecordingGranted: true, extensionSkipped: true)
        XCTAssertTrue(s.extensionStepComplete)
        XCTAssertEqual(s.currentStep, .registerAgents)
    }

    func testSkippedExtensionCanStillReachDone() {
        let s = OnboardingState(screenRecordingGranted: true, extensionSkipped: true,
                                agentsAcknowledged: true)
        XCTAssertEqual(s.currentStep, .done)
        XCTAssertTrue(s.isComplete)
    }

    func testExtensionFolderLocatorPrefersBundledExtension() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let bundledExtension = try makeExtension(at: resources)
        let executable = temporaryDirectory.appendingPathComponent("Lasso.app/Contents/MacOS/Lasso")

        let result = ExtensionFolderLocator.locate(resourceURL: resources, executableURL: executable)

        XCTAssertEqual(result, bundledExtension)
    }

    func testExtensionFolderLocatorFindsDevelopmentCheckout() throws {
        let checkout = temporaryDirectory.appendingPathComponent("checkout", isDirectory: true)
        let expected = try makeExtension(at: checkout)
        let executable = checkout
            .appendingPathComponent(".build/arm64-apple-macosx/debug/lasso-conductor")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let result = ExtensionFolderLocator.locate(resourceURL: nil, executableURL: executable)

        XCTAssertEqual(result, expected)
    }

    func testExtensionFolderLocatorFallsBackWhenBundledResourcesAreIncomplete() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let checkout = temporaryDirectory.appendingPathComponent("checkout", isDirectory: true)
        let expected = try makeExtension(at: checkout)
        let executable = checkout
            .appendingPathComponent(".build/arm64-apple-macosx/debug/lasso-conductor")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let result = ExtensionFolderLocator.locate(resourceURL: resources, executableURL: executable)

        XCTAssertEqual(result, expected)
    }

    func testExtensionFolderLocatorReturnsNilWithoutManifest() {
        let executable = temporaryDirectory
            .appendingPathComponent(".build/arm64-apple-macosx/debug/lasso-conductor")

        XCTAssertNil(ExtensionFolderLocator.locate(resourceURL: nil, executableURL: executable))
    }

    func testExtensionFolderOpenerPassesLocatedFolderToWorkspace() throws {
        let folder = try makeExtension(at: temporaryDirectory)
        var openedURL: URL?

        let result = ExtensionFolderLocator.open(folder) { url in
            openedURL = url
            return true
        }

        XCTAssertEqual(result, .opened)
        XCTAssertEqual(openedURL, folder)
    }

    func testExtensionFolderOpenerReportsMissingOrUnavailableFolder() throws {
        XCTAssertEqual(ExtensionFolderLocator.open(nil) { _ in true }, .folderMissing)
        let folder = try makeExtension(at: temporaryDirectory)
        XCTAssertEqual(ExtensionFolderLocator.open(folder) { _ in false }, .workspaceUnavailable)
    }

    @discardableResult
    private func makeExtension(at parent: URL) throws -> URL {
        let extensionDirectory = parent.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: extensionDirectory.appendingPathComponent("manifest.json").path,
                                       contents: Data())
        return extensionDirectory
    }
}
