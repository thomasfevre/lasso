import XCTest
import CSQLite
@testable import LassoCore

// Seam 1 (SPE-544): the Store / Capture contract. These exercise external
// behaviour — write fixture Captures, read them back — with no macOS capture in
// the loop.
final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lasso-test-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> Store {
        try Store(directory: dir)
    }

    private var png: Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }

    func testEmptyStoreHasNoLatest() throws {
        let store = try makeStore()
        XCTAssertNil(try store.latest())
        XCTAssertNil(try store.latestId())
        XCTAssertNil(try store.latest(afterId: 0))
    }

    func testLatestWins() throws {
        let store = try makeStore()
        let first = try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        let second = try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: "second")
        XCTAssertGreaterThan(second.id, first.id)

        let latest = try store.latest()
        XCTAssertEqual(latest?.id, second.id)
        XCTAssertEqual(latest?.note, "second")
        XCTAssertEqual(try store.latestId(), second.id)
    }

    func testRedactionStatusRoundTrips() throws {
        let store = try makeStore()
        let written = try store.insert(
            imagePNG: png,
            context: CaptureContext(source: .none),
            note: nil,
            redactionStatus: .redacted
        )
        XCTAssertEqual(written.redactionStatus, .redacted)
        XCTAssertEqual(try store.latest()?.redactionStatus, .redacted)
    }

    func testAfterIdFiltering() throws {
        let store = try makeStore()
        let a = try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)

        // after_id at or above the latest id => nothing newer.
        XCTAssertNil(try store.latest(afterId: a.id))
        XCTAssertNil(try store.latest(afterId: a.id + 1))
        // after_id below the latest id => the latest Capture.
        XCTAssertEqual(try store.latest(afterId: a.id - 1)?.id, a.id)

        let b = try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        // Once a newer Capture lands, the previously-seen id yields it.
        XCTAssertEqual(try store.latest(afterId: a.id)?.id, b.id)
    }

    func testAgeSeconds() throws {
        let store = try makeStore()
        let created = Date(timeIntervalSinceNow: -5)
        let capture = try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil, now: created)
        let age = capture.age(now: created.addingTimeInterval(5))
        XCTAssertEqual(age, 5, accuracy: 0.001)

        // Re-read from disk: created_at round-trips.
        let readBack = try store.latest()
        XCTAssertEqual(readBack?.createdAt.timeIntervalSince1970 ?? 0,
                       created.timeIntervalSince1970, accuracy: 0.001)
    }

    func testScreenContextRoundTrip() throws {
        let store = try makeStore()
        try store.insert(imagePNG: png, context: CaptureContext(source: .ocr, text: "hello"), note: "n")
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.context.source, .ocr)
        XCTAssertEqual(c.context.text, "hello")
        XCTAssertNil(c.context.dom)
        XCTAssertEqual(c.note, "n")
    }

    func testCodeLayoutContextRoundTrip() throws {
        let store = try makeStore()
        let text = "useCamelCase(user_id)\nsnake_case = true"
        try store.insert(
            imagePNG: png,
            context: CaptureContext(source: .ocr, text: text, layout: .code),
            note: nil
        )

        let context = try XCTUnwrap(try store.latest()).context
        XCTAssertEqual(context.text, text)
        XCTAssertEqual(context.layout, .code)
    }

    func testCaptureContextDecodesJSONFromBeforeLayoutField() throws {
        let data = Data(#"{"source":"ocr","text":"hello"}"#.utf8)

        let context = try JSONDecoder().decode(CaptureContext.self, from: data)

        XCTAssertEqual(context.source, .ocr)
        XCTAssertEqual(context.text, "hello")
        XCTAssertNil(context.layout)
    }

    func testDOMFingerprintRoundTrip() throws {
        let store = try makeStore()
        let dom = DOMFingerprint(
            selector: "button.primary",
            role: "button",
            text: "Save",
            nearbyText: "Cancel",
            componentName: "SaveButton",
            bbox: BBox(x: 1, y: 2, width: 3, height: 4)
        )
        try store.insert(imagePNG: png, context: CaptureContext(source: .dom, text: "Save", dom: dom), note: nil)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.context.source, .dom)
        XCTAssertEqual(c.context.dom, dom)
    }

    func testImageRoundTrip() throws {
        let store = try makeStore()
        let bytes = png + Data([1, 2, 3, 4, 5])
        try store.insert(imagePNG: bytes, context: CaptureContext(source: .none), note: nil)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(try store.imageData(for: c), bytes)
    }

    func testStoreAndCaptureFilesUseOwnerOnlyPermissions() throws {
        let store = try makeStore()
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)

        func permissions(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try permissions(dir), 0o700)
        XCTAssertEqual(try permissions(dir.appendingPathComponent("store.sqlite3")), 0o600)
        XCTAssertEqual(try permissions(dir.appendingPathComponent(capture.imageFile)), 0o600)
        for suffix in ["-wal", "-shm"] {
            let url = dir.appendingPathComponent("store.sqlite3" + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                XCTAssertEqual(try permissions(url), 0o600)
            }
        }
    }

    func testImageFilenameFromSQLiteCannotTraverse() throws {
        let store = try makeStore()
        try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try execute(storePath: dir.appendingPathComponent("store.sqlite3").path,
                    sql: "UPDATE captures SET image_file = '../secret.png';")

        let capture = try XCTUnwrap(try store.latest())
        XCTAssertThrowsError(try store.imageData(for: capture))
    }

    func testImageSymlinkIsRejected() throws {
        let store = try makeStore()
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        let imageURL = dir.appendingPathComponent(capture.imageFile)
        let target = dir.appendingPathComponent("target")
        try png.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.removeItem(at: imageURL)
        try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: target)

        XCTAssertThrowsError(try store.imageData(for: capture))
    }

    func testImageWithUnsafeModeIsRejected() throws {
        let store = try makeStore()
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        let imageURL = dir.appendingPathComponent(capture.imageFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: imageURL.path)

        XCTAssertThrowsError(try store.imageData(for: capture))
    }

    func testInvalidPNGSignatureIsRejected() throws {
        let store = try makeStore()
        let capture = try store.insert(imagePNG: Data(repeating: 0, count: 8),
                                       context: CaptureContext(), note: nil)
        XCTAssertThrowsError(try store.imageData(for: capture))
    }

    func testOversizedImageIsRejectedBeforeRead() throws {
        let store = try makeStore()
        let capture = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(capture.imageFile))
        try handle.truncate(atOffset: UInt64(Store.maximumImageBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try store.imageData(for: capture))
    }

    func testSymlinkedStoreDirectoryIsRejected() throws {
        let actual = dir.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        XCTAssertThrowsError(try Store(directory: link))
    }

    private func execute(storePath: String, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(storePath, &db) == SQLITE_OK else {
            throw XCTSkip("could not open test database")
        }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testTargetWindowContextRoundTrip() throws {
        let store = try makeStore()
        let ctx = CaptureContext(source: .ocr, text: "hi", appName: "Safari", windowTitle: "Lasso — Docs")
        try store.insert(imagePNG: png, context: ctx, note: nil)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.context.appName, "Safari")
        XCTAssertEqual(c.context.windowTitle, "Lasso — Docs")
    }

    func testMissingTargetWindowContextIsNil() throws {
        let store = try makeStore()
        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertNil(c.context.appName)
        XCTAssertNil(c.context.windowTitle)
    }

    // Simulate a v2 (markers, but pre-SPE-559) database: no app_name/window_title
    // columns. Opening as a writer migrates them in without losing the row, and
    // the legacy row reads back with nil target context.
    func testMigratesPreTargetColumnsDatabase() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("store.sqlite3").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let legacy = """
        CREATE TABLE captures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL, image_file TEXT NOT NULL, source TEXT NOT NULL,
            text TEXT, dom_json TEXT, note TEXT, markers_json TEXT
        );
        INSERT INTO captures (created_at, image_file, source, text, dom_json, note, markers_json)
        VALUES (1000.0, 'legacy.png', 'ocr', 'hi', NULL, 'old', NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try makeStore()
        let legacyRow = try XCTUnwrap(try store.latest())
        XCTAssertEqual(legacyRow.note, "old")
        XCTAssertNil(legacyRow.context.appName)
        XCTAssertNil(legacyRow.context.windowTitle)
        XCTAssertNil(legacyRow.context.layout)
        XCTAssertEqual(legacyRow.redactionStatus, .none)
        XCTAssertEqual(legacyRow.tags, [])
        XCTAssertEqual(legacyRow.libraryState, .recent)

        // New writes now carry the target context.
        try store.insert(imagePNG: png,
                         context: CaptureContext(source: .none, appName: "Code", windowTitle: "main.swift"),
                         note: nil)
        XCTAssertEqual(try store.latest()?.context.appName, "Code")
    }

    func testCaptureByIdReturnsMatchOrNil() throws {
        let store = try makeStore()
        let a = try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: "a")
        let b = try store.insert(imagePNG: png, context: CaptureContext(source: .ocr, text: "t"), note: "b")

        XCTAssertEqual(try store.capture(id: a.id)?.note, "a")
        let read = try XCTUnwrap(try store.capture(id: b.id))
        XCTAssertEqual(read.context.source, .ocr)
        XCTAssertEqual(read.context.text, "t")
        // An id that was never assigned is nil, not an error (ephemeral-purge case).
        XCTAssertNil(try store.capture(id: b.id + 999))
    }

    func testRecentReturnsNewestFirstAndRespectsLimit() throws {
        let store = try makeStore()
        var ids: [Int64] = []
        for i in 0..<4 { ids.append(try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: "\(i)").id) }

        let all = try store.recent(limit: 10)
        XCTAssertEqual(all.map(\.id), ids.reversed())

        let two = try store.recent(limit: 2)
        XCTAssertEqual(two.map(\.id), [ids[3], ids[2]])

        XCTAssertEqual(try store.recent(limit: 0).count, 0)
    }

    func testRecentOnEmptyStore() throws {
        XCTAssertEqual(try makeStore().recent(limit: 5).count, 0)
    }

    func testReadOnlyStoreReadsWhatWriterWrote() throws {
        let writer = try makeStore()
        let written = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: "ro")
        let reader = try Store(directory: dir, readOnly: true)
        XCTAssertEqual(try reader.latest()?.id, written.id)
        XCTAssertEqual(try reader.latest()?.note, "ro")
    }

    // MARK: - Capture requests (SPE-565)

    func testCaptureRequestRoundTripAndClear() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000)

        let inserted = try store.insertRequest(requester: "lasso-mcp (PID 42)", now: now)
        XCTAssertEqual(inserted.createdAt, now)
        XCTAssertEqual(inserted.requester, "lasso-mcp (PID 42)")
        XCTAssertEqual(try store.pendingRequests(now: now).map(\.id), [inserted.id])
        XCTAssertEqual(try store.pendingRequests(now: now).first?.requester, "lasso-mcp (PID 42)")

        try store.clearRequest(id: inserted.id)
        XCTAssertEqual(try store.pendingRequests(now: now).count, 0)
    }

    func testCaptureRequestExpiresWhenStale() throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_000)
        try store.insertRequest(now: created)

        let afterExpiry = created.addingTimeInterval(Store.requestMaxAgeSeconds + 1)
        XCTAssertEqual(try store.pendingRequests(now: afterExpiry).count, 0)
    }

    func testDuplicateCaptureRequestsCoalesce() throws {
        let store = try makeStore()
        let first = try store.insertRequest(requester: "first", now: Date(timeIntervalSince1970: 1_000))
        let duplicate = try store.insertRequest(requester: "second", now: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.createdAt, Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(duplicate.requester, "second")
        XCTAssertEqual(try store.pendingRequests(now: Date(timeIntervalSince1970: 1_001)).map(\.id), [first.id])
        XCTAssertEqual(try store.pendingRequests(now: Date(timeIntervalSince1970: 1_001)).first?.requester,
                       "second")
        // Expiry is refreshed by the duplicate rather than remaining anchored
        // to the nearly-stale first request.
        XCTAssertEqual(try store.pendingRequests(now: Date(timeIntervalSince1970: 1_300)).map(\.id), [first.id])
    }

    func testRequestWriterCannotInsertCapture() throws {
        let store = try Store(directory: dir, access: .requestWriter)
        try store.insertRequest(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertThrowsError(
            try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        )
        XCTAssertNil(try store.latest())
    }

    func testMigratesCaptureRequestsFromBeforeRequesterField() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("store.sqlite3").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL
            );
            INSERT INTO requests (created_at) VALUES (1000.0);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(directory: dir, access: .requestWriter)
        let request = try XCTUnwrap(try store.pendingRequests(now: Date(timeIntervalSince1970: 1_001)).first)
        XCTAssertEqual(request.requester, "Local MCP client")
    }

    func testExpiredCaptureRequestIsReplaced() throws {
        let store = try makeStore()
        let first = try store.insertRequest(now: Date(timeIntervalSince1970: 1_000))
        let replacementTime = Date(timeIntervalSince1970: 1_000 + Store.requestMaxAgeSeconds + 1)
        let replacement = try store.insertRequest(now: replacementTime)

        XCTAssertGreaterThan(replacement.id, first.id)
        XCTAssertEqual(try store.pendingRequests(now: replacementTime).map(\.id), [replacement.id])
    }

    func testCaptureClearsOnlyRequestsThatAlreadyExisted() throws {
        let store = try makeStore()
        let old = try store.insertRequest(now: Date(timeIntervalSince1970: 1_000))
        try store.clearRequests(createdThrough: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try store.pendingRequests(now: Date(timeIntervalSince1970: 1_000)).count, 0)

        let newer = try store.insertRequest(now: Date(timeIntervalSince1970: 2_000))
        try store.clearRequests(createdThrough: Date(timeIntervalSince1970: 1_999))
        XCTAssertNotEqual(newer.id, old.id)
        XCTAssertEqual(try store.pendingRequests(now: Date(timeIntervalSince1970: 2_000)).map(\.id), [newer.id])
    }
}
