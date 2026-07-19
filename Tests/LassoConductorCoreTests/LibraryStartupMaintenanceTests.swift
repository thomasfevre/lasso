import Foundation
import XCTest
@testable import LassoConductorCore
import LassoCore

final class LibraryStartupMaintenanceTests: XCTestCase {
    func testRunAppliesConfiguredRetentionBeforeTheLibraryIsShown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lasso-startup-maintenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let longRetention = Retention(maxCaptures: 100, duration: .thirtyDays)
        let writer = try Store(directory: directory, retention: longRetention)
        _ = try writer.insert(
            imagePNG: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            context: CaptureContext(),
            note: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let shortRetention = Retention(maxCaptures: 100, duration: .sevenDays)
        let startupStore = try Store(directory: directory, retention: shortRetention)
        try LibraryStartupMaintenance.run(
            store: startupStore,
            now: Date(timeIntervalSince1970: 1_700_000_000 + (8 * 24 * 60 * 60)),
            abandonedShareCleanup: {}
        )

        XCTAssertEqual(try startupStore.count(in: .recent), 0)
    }

    func testRunRemovesOrphanedCaptureImagesWithoutTouchingReferencedImages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lasso-startup-orphans-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let referenced = try store.insert(
            imagePNG: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            context: CaptureContext(),
            note: nil
        )
        let orphan = directory.appendingPathComponent("\(UUID().uuidString.uppercased()).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(2 * 60 * 60))],
            ofItemAtPath: orphan.path
        )

        try LibraryStartupMaintenance.run(store: store, abandonedShareCleanup: {})

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(referenced.imageFile).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testRunRemovesAFreshUnreferencedImageOnceNoWriterOwnsTheLifecycleLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lasso-startup-fresh-image-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let freshImage = directory.appendingPathComponent("\(UUID().uuidString.uppercased()).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: freshImage)

        try LibraryStartupMaintenance.run(store: store, abandonedShareCleanup: {})

        XCTAssertFalse(FileManager.default.fileExists(atPath: freshImage.path))
    }

    func testOrphanSweepStillRunsWhenRetentionCleanupReportsAnError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lasso-startup-retention-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(
            directory: directory,
            retention: Retention(maxCaptures: 100, duration: .oneHour)
        )
        let expired = try store.insert(
            imagePNG: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            context: CaptureContext(),
            note: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let blockedURL = directory.appendingPathComponent(expired.imageFile)
        try FileManager.default.removeItem(at: blockedURL)
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        let orphan = directory.appendingPathComponent("\(UUID().uuidString.uppercased()).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: orphan)

        XCTAssertThrowsError(try LibraryStartupMaintenance.run(
            store: store,
            now: Date(timeIntervalSince1970: 1_700_000_000 + 7_200),
            abandonedShareCleanup: {}
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertNil(try store.capture(id: expired.id))
    }
}
