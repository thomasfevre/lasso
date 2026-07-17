import XCTest
import CSQLite
@testable import LassoCore

// SPE-554: pin markers on the Capture contract.
final class MarkerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lasso-marker-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var png: Data { Data([0x89, 0x50, 0x4E, 0x47]) }

    func testDefaultMarkersEmptyAndNoteUnchanged() throws {
        let store = try Store(directory: dir)
        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: "just a note")
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.markers, [])
        XCTAssertEqual(c.note, "just a note")
    }

    func testMarkersRoundTrip() throws {
        let store = try Store(directory: dir)
        let markers = [
            Marker(index: 1, x: 0.1, y: 0.2, note: "this button"),
            Marker(index: 2, x: 0.9, y: 0.95, note: nil),
        ]
        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil, markers: markers)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.markers, markers)
    }

    // SPE-560: per-pin element resolution rides on the marker JSON (Codable), so
    // no schema/column change — dom and text round-trip through the same column.
    func testPerPinResolutionRoundTrip() throws {
        let store = try Store(directory: dir)
        let markers = [
            Marker(index: 1, x: 0.2, y: 0.3, note: "web",
                   dom: DOMFingerprint(selector: "#buy", role: "button", componentName: "BuyButton")),
            Marker(index: 2, x: 0.7, y: 0.8, note: "screen", text: "Total: $42"),
        ]
        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil, markers: markers)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.markers, markers)
        XCTAssertEqual(c.markers[0].dom?.selector, "#buy")
        XCTAssertEqual(c.markers[1].text, "Total: $42")
    }

    // A v2 marker JSON (no dom/text keys) still decodes — the fields are optional.
    func testLegacyMarkerJSONDecodesWithNilResolution() throws {
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
        VALUES (1000.0, 'legacy.png', 'none', NULL, NULL, NULL,
                '[{"index":1,"x":0.5,"y":0.5,"note":"old pin"}]');
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(directory: dir)
        let c = try XCTUnwrap(try store.latest())
        XCTAssertEqual(c.markers.count, 1)
        XCTAssertEqual(c.markers[0].note, "old pin")
        XCTAssertNil(c.markers[0].dom)
        XCTAssertNil(c.markers[0].text)
    }

    func testMarkerValidation() throws {
        XCTAssertTrue(Marker(index: 1, x: 0, y: 1).isValid)
        XCTAssertFalse(Marker(index: 0, x: 0.5, y: 0.5).isValid)   // pin number must be >= 1
        XCTAssertFalse(Marker(index: 1, x: -0.01, y: 0.5).isValid) // x below range
        XCTAssertFalse(Marker(index: 1, x: 0.5, y: 1.01).isValid)  // y above range
    }

    func testInsertRejectsInvalidMarker() throws {
        let store = try Store(directory: dir)
        XCTAssertThrowsError(
            try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil,
                             markers: [Marker(index: 1, x: 1.5, y: 0.5)])
        )
        // The rejected write leaves nothing behind.
        XCTAssertEqual(try store.count(), 0)
    }

    func testInsertRejectsDuplicateIndices() throws {
        let store = try Store(directory: dir)
        XCTAssertThrowsError(
            try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil,
                             markers: [Marker(index: 1, x: 0.1, y: 0.1),
                                       Marker(index: 1, x: 0.2, y: 0.2)])
        )
        XCTAssertEqual(try store.count(), 0)
    }

    func testNaNAndInfiniteCoordinatesRejected() throws {
        XCTAssertFalse(Marker(index: 1, x: .nan, y: 0.5).isValid)
        XCTAssertFalse(Marker(index: 1, x: 0.5, y: .infinity).isValid)
        let store = try Store(directory: dir)
        XCTAssertThrowsError(
            try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil,
                             markers: [Marker(index: 1, x: .nan, y: 0.5)])
        )
    }

    func testReaderOnPreMarkersDatabaseYieldsEmptyMarkers() throws {
        // A v1 database that a writer never migrated, opened directly read-only:
        // the absent markers_json column must degrade to empty markers, not fail.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("store.sqlite3").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let legacy = """
        CREATE TABLE captures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL, image_file TEXT NOT NULL, source TEXT NOT NULL,
            text TEXT, dom_json TEXT, note TEXT
        );
        INSERT INTO captures (created_at, image_file, source, text, dom_json, note)
        VALUES (1000.0, 'legacy.png', 'none', NULL, NULL, 'old');
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let reader = try Store(directory: dir, readOnly: true)
        XCTAssertFalse(reader.hasMarkersColumnForTesting)
        let c = try XCTUnwrap(try reader.latest())
        XCTAssertEqual(c.note, "old")
        XCTAssertEqual(c.markers, [])
    }

    func testEmptyMarkersStoredAsNullNotEmptyArray() throws {
        // An empty markers list should not persist a JSON blob; it reads back empty.
        let store = try Store(directory: dir)
        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil, markers: [])
        XCTAssertEqual(try store.latest()?.markers, [])
    }

    // Simulate a pre-markers (v1) database: create the old schema by hand, insert
    // a row, then open with the current Store and confirm it migrates the column
    // in without losing the row, and that new writes carry markers.
    func testMigratesPreMarkersDatabase() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("store.sqlite3").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let legacy = """
        CREATE TABLE captures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL, image_file TEXT NOT NULL, source TEXT NOT NULL,
            text TEXT, dom_json TEXT, note TEXT
        );
        INSERT INTO captures (created_at, image_file, source, text, dom_json, note)
        VALUES (1000.0, 'legacy.png', 'none', NULL, NULL, 'old capture');
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // Opening as a writer migrates the schema; the legacy row survives.
        let store = try Store(directory: dir)
        let legacyRow = try XCTUnwrap(try store.latest())
        XCTAssertEqual(legacyRow.note, "old capture")
        XCTAssertEqual(legacyRow.markers, [])

        // New writes now carry markers.
        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil,
                         markers: [Marker(index: 1, x: 0.5, y: 0.5, note: "pin")])
        XCTAssertEqual(try store.latest()?.markers.first?.note, "pin")
    }

    func testReaderReadsMarkers() throws {
        let writer = try Store(directory: dir)
        try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil,
                          markers: [Marker(index: 1, x: 0.3, y: 0.7, note: "here")])
        let reader = try Store(directory: dir, readOnly: true)
        XCTAssertEqual(reader.hasMarkersColumnForTesting, true)
        XCTAssertEqual(try reader.latest()?.markers.first?.note, "here")
    }
}
