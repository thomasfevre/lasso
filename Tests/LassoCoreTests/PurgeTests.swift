import XCTest
@testable import LassoCore

// SPE-551: the Store is a short ephemeral spool, not an archive. It keeps only
// the newest `maxCaptures` and drops anything older than the configured duration,
// removing both the row and the PNG.
final class PurgeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lasso-purge-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var png: Data { Data([0x89, 0x50, 0x4E, 0x47]) }

    private func pngCount() throws -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".png") }.count
    }

    private func store(
        maxCaptures: Int = 10,
        duration: RetentionDuration = .oneHour
    ) throws -> Store {
        try Store(
            directory: dir,
            retention: Retention(maxCaptures: maxCaptures, duration: duration)
        )
    }

    func testKeepsOnlyNewestMaxCaptures() throws {
        let s = try store(maxCaptures: 3)
        var last: Capture!
        for _ in 0..<5 { last = try s.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil) }
        XCTAssertEqual(try s.count(), 3)
        XCTAssertEqual(try s.latest()?.id, last.id)
        // Purged rows take their PNG with them.
        XCTAssertEqual(try pngCount(), 3)
    }

    func testPurgesByAge() throws {
        let s = try store(maxCaptures: 100, duration: .oneHour)
        // An old Capture, then a fresh one. The fresh insert's purge drops the old.
        _ = try s.insert(imagePNG: png, context: CaptureContext(source: .none), note: "old",
                         now: Date(timeIntervalSinceNow: -7200))
        let fresh = try s.insert(imagePNG: png, context: CaptureContext(source: .none), note: "fresh")
        XCTAssertEqual(try s.count(), 1)
        XCTAssertEqual(try s.latest()?.id, fresh.id)
        XCTAssertEqual(try pngCount(), 1)
    }

    func testAfterIdStillCorrectAcrossPurgedWindow() throws {
        let s = try store(maxCaptures: 3)
        var ids: [Int64] = []
        for _ in 0..<5 { ids.append(try s.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil).id) }
        // ids[0] and ids[1] are purged; after_id referencing a purged id still
        // yields the current latest, and after_id at the latest yields nothing.
        XCTAssertEqual(try s.latest(afterId: ids[0])?.id, ids[4])
        XCTAssertNil(try s.latest(afterId: ids[4]))
    }

    func testConfiguredRetentionKeepsTen() throws {
        let s = try store()
        for _ in 0..<12 { _ = try s.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil) }
        XCTAssertEqual(try s.count(), 10)
    }

    func testPurgeSurvivesReopen() throws {
        do {
            let s = try store(maxCaptures: 2)
            for _ in 0..<4 { _ = try s.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil) }
            XCTAssertEqual(try s.count(), 2)
        }
        // Reopening sees the purged state, not resurrected rows.
        let reopened = try store(maxCaptures: 2)
        XCTAssertEqual(try reopened.count(), 2)
    }
}
