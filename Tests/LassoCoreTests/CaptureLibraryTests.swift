import XCTest
@testable import LassoCore

final class CaptureLibraryTests: XCTestCase {
    private var directory: URL!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lasso-library-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testTrashHidesCaptureUntilItIsRestoredToItsOriginalState() throws {
        let store = try Store(directory: directory)
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try store.setKept(true, id: capture.id)
        try store.moveToTrash(id: capture.id)

        XCTAssertNil(try store.latest())
        XCTAssertEqual(try store.capture(id: capture.id)?.libraryState, .recentlyDeleted)
        XCTAssertEqual(try store.captures(in: .recentlyDeleted).first?.deletedFromState, .kept)

        try store.restore(id: capture.id)
        XCTAssertEqual(try store.latest()?.libraryState, .kept)
    }

    func testTagsRoundTripAndEmptyTagsAreRemoved() throws {
        let store = try Store(directory: directory)
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try store.updateTags([" review ", "review", "", "bug"], id: capture.id)

        XCTAssertEqual(try store.capture(id: capture.id)?.tags, ["bug", "review"])
    }

    func testTagsNormalizeCasingAndWhitespaceAcrossEveryWriter() throws {
        let store = try Store(directory: directory)
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try store.updateTags([" Review ", "review", "RÉVIEW", "bug"], id: capture.id)

        XCTAssertEqual(try store.capture(id: capture.id)?.tags, ["bug", "Review"])
        XCTAssertEqual(try store.activeTags(), ["bug", "Review"])
    }

    func testSearchIncludesOCRTextAlongsideNotesPinsTagsAndWindowMetadata() throws {
        let store = try Store(directory: directory)
        let matching = try store.insert(imagePNG: png,
                                        context: CaptureContext(appName: "Safari", windowTitle: "Dashboard review"),
                                        note: "check spacing", markers: [Marker(index: 1, x: 0.5, y: 0.5, note: "CTA")])
        try store.updateTags(["client-a"], id: matching.id)
        let ocrOnly = try store.insert(imagePNG: png,
                                       context: CaptureContext(text: "secret unique OCR phrase"), note: nil)
        let domOnly = try store.insert(
            imagePNG: png,
            context: CaptureContext(
                source: .dom,
                dom: DOMFingerprint(
                    selector: "main > section",
                    text: "Quarterly pipeline",
                    nearbyText: "Revenue forecast"
                )
            ),
            note: nil
        )

        XCTAssertEqual(try store.searchCaptures(query: "dashboard").map(\.id), [matching.id])
        XCTAssertEqual(try store.searchCaptures(query: "cta").map(\.id), [matching.id])
        XCTAssertEqual(try store.searchCaptures(query: "unique OCR phrase").map(\.id), [ocrOnly.id])
        XCTAssertEqual(try store.searchCaptures(query: "Quarterly pipeline").map(\.id), [domOnly.id])
        XCTAssertEqual(try store.searchCaptures(query: "Revenue forecast").map(\.id), [domOnly.id])
        XCTAssertEqual(try store.searchCaptures(query: "", tag: "client-a").map(\.id), [matching.id])
        XCTAssertFalse((try store.activeTags()).contains("unused"))
    }

    func testKeptCaptureSurvivesRecentRetentionCap() throws {
        let store = try Store(
            directory: directory,
            retention: Retention(
                maxCaptures: 1,
                duration: try XCTUnwrap(RetentionDuration(seconds: 60))
            )
        )
        let kept = try store.insert(imagePNG: png, context: CaptureContext(), note: "keep")
        try store.setKept(true, id: kept.id)
        let recent = try store.insert(imagePNG: png, context: CaptureContext(), note: "recent")
        _ = try store.insert(imagePNG: png, context: CaptureContext(), note: "newest")

        XCTAssertEqual(try store.capture(id: kept.id)?.libraryState, .kept)
        XCTAssertNil(try store.capture(id: recent.id))
    }

    func testExpiredTrashIsPermanentlyRemovedWithItsImage() throws {
        let store = try Store(
            directory: directory,
            retention: Retention(
                maxCaptures: 100,
                duration: try XCTUnwrap(RetentionDuration(seconds: 60))
            )
        )
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try store.moveToTrash(id: capture.id, now: Date(timeIntervalSinceNow: -120))

        try store.applyRetention()
        XCTAssertNil(try store.capture(id: capture.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(capture.imageFile).path))
    }

    func testEmptyRecentlyDeletedRemovesOnlyTrashRowsAndImages() throws {
        let store = try Store(directory: directory)
        let recent = try store.insert(imagePNG: png, context: CaptureContext(), note: "recent")
        let firstTrash = try store.insert(imagePNG: png, context: CaptureContext(), note: "trash one")
        let secondTrash = try store.insert(imagePNG: png, context: CaptureContext(), note: "trash two")
        try store.moveToTrash(id: firstTrash.id)
        try store.moveToTrash(id: secondTrash.id)

        XCTAssertEqual(try store.emptyRecentlyDeleted(), 2)

        XCTAssertNotNil(try store.capture(id: recent.id))
        XCTAssertNil(try store.capture(id: firstTrash.id))
        XCTAssertNil(try store.capture(id: secondTrash.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(recent.imageFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstTrash.imageFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(secondTrash.imageFile).path))
    }

    func testLibraryStateCountsAreExactAndExcludeOtherStates() throws {
        let store = try Store(directory: directory)
        let recent = try store.insert(imagePNG: png, context: CaptureContext(), note: "recent")
        let kept = try store.insert(imagePNG: png, context: CaptureContext(), note: "kept")
        let deleted = try store.insert(imagePNG: png, context: CaptureContext(), note: "deleted")
        try store.setKept(true, id: kept.id)
        try store.moveToTrash(id: deleted.id)

        XCTAssertEqual(try store.count(in: .recent), 1)
        XCTAssertEqual(try store.count(in: .kept), 1)
        XCTAssertEqual(try store.count(in: .recentlyDeleted), 1)
        XCTAssertEqual(try store.capture(id: recent.id)?.libraryState, .recent)
    }

    func testEmptyRecentlyDeletedNeverRestoresARowAfterItsImageCleanupFails() throws {
        let store = try Store(directory: directory)
        let first = try store.insert(imagePNG: png, context: CaptureContext(), note: "first")
        let blocked = try store.insert(imagePNG: png, context: CaptureContext(), note: "blocked")
        let untouched = try store.insert(imagePNG: png, context: CaptureContext(), note: "untouched")
        try store.moveToTrash(id: first.id)
        try store.moveToTrash(id: blocked.id)
        try store.moveToTrash(id: untouched.id)
        let blockedURL = directory.appendingPathComponent(blocked.imageFile)
        try FileManager.default.removeItem(at: blockedURL)
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.emptyRecentlyDeleted()) { error in
            XCTAssertTrue(error is StoreError)
        }
        XCTAssertNil(try store.capture(id: first.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(first.imageFile).path
        ))
        XCTAssertNil(try store.capture(id: blocked.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedURL.path))
        XCTAssertNil(try store.capture(id: untouched.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(untouched.imageFile).path
        ))
    }
}
