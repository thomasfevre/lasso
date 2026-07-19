import Foundation
import XCTest
@testable import LassoConductorCore

final class TemporaryArtifactLeaseTests: XCTestCase {
    func testReleaseRemovesTheArtifactAndIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lasso-share-\(UUID().uuidString).zip")
        try Data("temporary".utf8).write(to: url)
        let lease = TemporaryArtifactLease(url: url)

        XCTAssertTrue(lease.release())
        XCTAssertTrue(lease.release())

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedRemovalCanBeRetried() {
        enum RemovalFailure: Error { case expected }
        let url = URL(fileURLWithPath: "/tmp/lasso-retry.zip")
        var attempts = 0
        let lease = TemporaryArtifactLease(url: url) { _ in
            attempts += 1
            if attempts == 1 { throw RemovalFailure.expected }
        }

        XCTAssertFalse(lease.release())
        XCTAssertTrue(lease.release())
        XCTAssertTrue(lease.release())
        XCTAssertEqual(attempts, 2)
    }

    func testAbandonedCleanupRemovesOnlyOldZipArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lasso-share-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldZip = directory.appendingPathComponent("Lasso export old.zip")
        let oldStaging = directory.appendingPathComponent("Lasso export interrupted", isDirectory: true)
        let freshZip = directory.appendingPathComponent("Lasso export fresh.zip")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data().write(to: oldZip)
        try FileManager.default.createDirectory(at: oldStaging, withIntermediateDirectories: false)
        try Data().write(to: oldStaging.appendingPathComponent("original.png"))
        try Data().write(to: freshZip)
        try Data().write(to: unrelated)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: oldZip.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: oldStaging.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshZip.path
        )

        XCTAssertEqual(try TemporaryArtifactLease.removeAbandonedArtifacts(
            in: directory,
            olderThan: 3_600,
            now: now
        ), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldZip.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshZip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
