import Foundation
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errors surfaced by the Store.
public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)
    case access(String)
    case imageWrite(String)
    case imageRead(String)
    case imageDelete(String)
    case invalidMarker(String)

    public var description: String {
        switch self {
        case .open(let m): return "store open failed: \(m)"
        case .sql(let m): return "sqlite error: \(m)"
        case .access(let m): return "store access denied: \(m)"
        case .imageWrite(let m): return "image write failed: \(m)"
        case .imageRead(let m): return "image read failed: \(m)"
        case .imageDelete(let m): return "image delete failed: \(m)"
        case .invalidMarker(let m): return "invalid marker: \(m)"
        }
    }
}

/// Process roles are explicit so a Hub that writes capture requests never gains
/// the Conductor's ability to write Captures.
public enum StoreAccess: Sendable {
    case captureWriter
    case requestWriter
    case reader
}

// SQLite wants a destructor telling it to copy bound text/blob buffers.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A validated lifetime for Recent captures and Recently Deleted items.
public struct RetentionDuration: Equatable, Hashable, Sendable {
    public let seconds: TimeInterval

    public init?(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return nil }
        self.seconds = seconds
    }

    public static let oneHour = RetentionDuration(uncheckedSeconds: 60 * 60)
    public static let oneDay = RetentionDuration(uncheckedSeconds: 24 * 60 * 60)
    public static let sevenDays = RetentionDuration(uncheckedSeconds: 7 * 24 * 60 * 60)
    public static let thirtyDays = RetentionDuration(uncheckedSeconds: 30 * 24 * 60 * 60)
    public static let ninetyDays = RetentionDuration(uncheckedSeconds: 90 * 24 * 60 * 60)
    public static let `default` = sevenDays
    public static let supported: [RetentionDuration] = [
        .oneHour, .oneDay, .sevenDays, .thirtyDays, .ninetyDays,
    ]

    public static func persisted(seconds: TimeInterval) -> RetentionDuration {
        guard seconds.isFinite else { return .default }
        return supported.first { abs($0.seconds - seconds) < 1 } ?? .default
    }

    private init(uncheckedSeconds: TimeInterval) {
        seconds = uncheckedSeconds
    }
}

/// How long the local library keeps Recent captures and Recently Deleted items.
/// Kept captures are intentionally excluded from automatic expiry.
public struct Retention: Sendable {
    public var maxCaptures: Int
    public var duration: RetentionDuration

    public init(maxCaptures: Int, duration: RetentionDuration) {
        self.maxCaptures = maxCaptures
        self.duration = duration
    }

    public static let `default` = Retention(maxCaptures: 100, duration: .default)
}

/// A pending Agent request for the human to make a Capture. Requests are a
/// separate coordination channel from Captures: creating one never creates a
/// Capture and never invokes the Conductor's Overlay.
public struct CaptureRequest: Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let requester: String

    public init(id: Int64, createdAt: Date, requester: String = "Local MCP client") {
        self.id = id
        self.createdAt = createdAt
        self.requester = requester
    }
}

/// The Store: an ephemeral local spool of Captures (SQLite + PNG files) owned by
/// the Conductor and read by every Hub (ADR 0009), plus a separate request
/// channel that Hubs may write (ADR 0012). Only the Conductor's capture path
/// writes rows to `captures`.
public final class Store {
    /// A request older than this is discarded instead of nudging the user
    /// forever. Five minutes is long enough for an Agent polling loop while
    /// remaining clearly tied to the current interaction.
    public static let requestMaxAgeSeconds: Double = 5 * 60
    /// Raw PNG bytes are bounded before allocation/base64 encoding by the Hub.
    public static let maximumImageBytes = 25 * 1024 * 1024
    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    public let directory: URL
    private let dbPath: URL
    private let directoryFD: Int32
    private var db: OpaquePointer?
    private let retention: Retention
    private let access: StoreAccess
    private let hasCapturesTable: Bool
    /// Whether the `markers_json` column is present. A writer always migrates it
    /// in; a reader against a pre-markers database sees false and yields empty
    /// markers rather than failing.
    private let hasMarkersColumn: Bool
    /// Whether the target-window columns (`app_name`, `window_title`, SPE-559) are
    /// present. Same migration story as markers: a writer adds them, a reader
    /// against an older database sees false and yields nil for both.
    private let hasTargetColumns: Bool
    /// Whether the optional code-aware OCR layout hint (SPE-564) is present.
    /// Readers against older databases yield nil without attempting a migration.
    private let hasLayoutColumn: Bool
    /// Whether the capture-redaction outcome (SPE-580) is present.
    private let hasRedactionStatusColumn: Bool
    private let hasTagsColumn: Bool
    private let hasLibraryColumns: Bool

    /// Opens (creating if needed) the Store rooted at `directory`. A writer opens
    /// read-write and puts the database into WAL. A `.reader` (how a Hub consumes
    /// Captures owned by another process) also opens SQLite
    /// read-write but is pinned to logical read-only via `PRAGMA query_only=ON`,
    /// which is required to read a WAL database without being able to mutate it.
    /// `busyTimeoutMs` bounds how long a connection waits on a locked database.
    public init(directory: URL, access: StoreAccess, busyTimeoutMs: Int = 2000,
                retention: Retention = .default) throws {
        self.directory = directory
        self.dbPath = directory.appendingPathComponent("store.sqlite3")
        self.retention = retention
        self.access = access

        if access != .reader {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let openedDirectoryFD = try Store.openStoreDirectory(directory)
        self.directoryFD = openedDirectoryFD
        var openedHandle: OpaquePointer?
        var initialized = false
        defer {
            if !initialized {
                if let openedHandle { sqlite3_close(openedHandle) }
                close(openedDirectoryFD)
            }
        }

        try Store.secureSQLiteFile(
            directoryFD: openedDirectoryFD,
            name: "store.sqlite3",
            create: access != .reader
        )
        try Store.secureSQLiteFile(directoryFD: openedDirectoryFD, name: "store.sqlite3-wal")
        try Store.secureSQLiteFile(directoryFD: openedDirectoryFD, name: "store.sqlite3-shm")

        // A reader opens read-write (never CREATE) but is pinned to query-only
        // below. Pure SQLITE_OPEN_READONLY cannot manage the WAL shared-memory
        // (-shm) file, so it fails against a WAL database; read-write + query_only
        // is the supported way to read a WAL Store without mutating its data.
        let flags = access == .reader
            ? SQLITE_OPEN_READWRITE
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(dbPath.path, &openedHandle, flags, nil) == SQLITE_OK,
              let handle = openedHandle else {
            let msg = openedHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.open(msg)
        }
        self.db = handle

        // Init-time SQL uses the static exec: instance methods can't be called
        // until every stored property (below) is initialized.
        //
        // Multi-client (ADR 0005 / 0012): the Conductor writes Captures while
        // Hubs read them and may write requests concurrently. WAL lets readers
        // proceed without blocking a writer, and the timeout absorbs brief locks.
        try Store.exec(handle, "PRAGMA busy_timeout=\(busyTimeoutMs);")
        if access == .reader {
            // Pin the connection to reads: any write statement fails, so a Hub
            // cannot mutate a Store it does not own, while still building the
            // WAL shared-memory it needs to read.
            try Store.exec(handle, "PRAGMA query_only=ON;")
        } else {
            try Store.exec(handle, "PRAGMA journal_mode=WAL;")
            if access == .captureWriter {
                try Store.exec(handle, """
                CREATE TABLE IF NOT EXISTS captures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    image_file TEXT NOT NULL,
                    source TEXT NOT NULL,
                    text TEXT,
                    dom_json TEXT,
                    note TEXT,
                    markers_json TEXT,
                    app_name TEXT,
                    window_title TEXT,
                    layout TEXT,
                    redaction_status TEXT NOT NULL DEFAULT 'none',
                    tags_json TEXT,
                    library_state TEXT NOT NULL DEFAULT 'recent',
                    deleted_at REAL,
                    deleted_from_state TEXT
                );
                """)
            }
            // SPE-565: Hubs write only this coordination table. Captures remain
            // on the Conductor's existing write path; a request is never a
            // synthetic Capture and cannot trigger the Overlay by itself.
            try Store.exec(handle, """
            CREATE TABLE IF NOT EXISTS requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                requester TEXT NOT NULL DEFAULT 'Local MCP client'
            );
            """)
            if !Store.columnExists(handle, table: "requests", column: "requester") {
                try Store.exec(handle,
                    "ALTER TABLE requests ADD COLUMN requester TEXT NOT NULL DEFAULT 'Local MCP client';")
            }
            if access == .captureWriter {
                // Migrate a database created before markers (ADR 0011): add the
                // column in place, no data loss. New databases already have it.
                if !Store.columnExists(handle, table: "captures", column: "markers_json") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN markers_json TEXT;")
                }
                // Migrate a database created before the target-window columns (SPE-559).
                if !Store.columnExists(handle, table: "captures", column: "app_name") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN app_name TEXT;")
                }
                if !Store.columnExists(handle, table: "captures", column: "window_title") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN window_title TEXT;")
                }
                // Migrate a database created before the code-aware OCR layout hint (SPE-564).
                if !Store.columnExists(handle, table: "captures", column: "layout") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN layout TEXT;")
                }
                if !Store.columnExists(handle, table: "captures", column: "redaction_status") {
                    try Store.exec(handle,
                        "ALTER TABLE captures ADD COLUMN redaction_status TEXT NOT NULL DEFAULT 'none';")
                }
                if !Store.columnExists(handle, table: "captures", column: "tags_json") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN tags_json TEXT;")
                }
                if !Store.columnExists(handle, table: "captures", column: "library_state") {
                    try Store.exec(handle,
                        "ALTER TABLE captures ADD COLUMN library_state TEXT NOT NULL DEFAULT 'recent';")
                }
                if !Store.columnExists(handle, table: "captures", column: "deleted_at") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN deleted_at REAL;")
                }
                if !Store.columnExists(handle, table: "captures", column: "deleted_from_state") {
                    try Store.exec(handle, "ALTER TABLE captures ADD COLUMN deleted_from_state TEXT;")
                }
            }
        }

        self.hasCapturesTable = Store.tableExists(handle, table: "captures")
        self.hasMarkersColumn = Store.columnExists(handle, table: "captures", column: "markers_json")
        self.hasTargetColumns = Store.columnExists(handle, table: "captures", column: "app_name")
            && Store.columnExists(handle, table: "captures", column: "window_title")
        self.hasLayoutColumn = Store.columnExists(handle, table: "captures", column: "layout")
        self.hasRedactionStatusColumn = Store.columnExists(
            handle, table: "captures", column: "redaction_status")
        self.hasTagsColumn = Store.columnExists(handle, table: "captures", column: "tags_json")
        self.hasLibraryColumns = Store.columnExists(handle, table: "captures", column: "library_state")
            && Store.columnExists(handle, table: "captures", column: "deleted_at")
            && Store.columnExists(handle, table: "captures", column: "deleted_from_state")
        // Every stored property is initialized now, so any later throw runs
        // deinit. Hand cleanup ownership to deinit before the final throwing call.
        initialized = true
        try secureExistingStoreFiles()
    }

    /// Compatibility initializer for the established capture-writer/reader API.
    /// New coordination code should select an explicit `StoreAccess` role.
    public convenience init(directory: URL, readOnly: Bool = false, busyTimeoutMs: Int = 2000,
                            retention: Retention = .default) throws {
        try self.init(directory: directory, access: readOnly ? .reader : .captureWriter,
                      busyTimeoutMs: busyTimeoutMs, retention: retention)
    }

    private static func tableExists(_ db: OpaquePointer?, table: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
            -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Whether `table` has `column`, via `PRAGMA table_info`. Static so it can run
    /// during `init` before `self` is fully formed.
    private static func columnExists(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    deinit {
        if let db { sqlite3_close(db) }
        close(directoryFD)
    }

    /// Test-only view of whether the markers column was detected/migrated.
    var hasMarkersColumnForTesting: Bool { hasMarkersColumn }

    /// The default Store location. macOS uses the fixed Application Support path
    /// (ADR 0009); other platforms fall back to the user data dir (used for the
    /// Linux test/dev build). `LASSO_STORE_DIR` overrides both.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["LASSO_STORE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Lasso", isDirectory: true)
    }

    // MARK: - Writer (Conductor / seeding)

    /// Writes a PNG plus its context as a new Capture and returns it (with the
    /// assigned monotonic id). Used by the Conductor later, and by `lasso-seed`.
    @discardableResult
    public func insert(imagePNG: Data, context: CaptureContext, note: String?,
                       markers: [Marker] = [], redactionStatus: RedactionStatus = .none,
                       now: Date = Date()) throws -> Capture {
        guard access == .captureWriter else {
            throw StoreError.access("only the Conductor capture writer may insert Captures")
        }
        // Validate markers before doing anything expensive.
        for marker in markers where !marker.isValid {
            throw StoreError.invalidMarker("index \(marker.index) at (\(marker.x), \(marker.y))")
        }
        // Pin numbers must be unique, otherwise a marker reference is ambiguous.
        let indices = markers.map(\.index)
        if Set(indices).count != indices.count {
            throw StoreError.invalidMarker("duplicate pin index in \(indices)")
        }

        // Prepare everything that can fail cheaply before touching the disk, so
        // a bad row never leaves an orphan PNG behind.
        let domJSON = try context.dom.map { try encodeDOM($0) }
        let markersJSON = try markers.isEmpty ? nil : encodeMarkers(markers)
        let stmt = try prepare("""
        INSERT INTO captures (created_at, image_file, source, text, dom_json, note, markers_json, app_name, window_title, layout, redaction_status, tags_json, library_state, deleted_at, deleted_from_state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'recent', NULL, NULL);
        """)
        defer { sqlite3_finalize(stmt) }

        let fileName = UUID().uuidString + ".png"
        var wroteImage = false
        do {
            let fd = openat(directoryFD, fileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw StoreError.imageWrite(Store.systemError()) }
            guard fchmod(fd, 0o600) == 0 else {
                let message = Store.systemError()
                close(fd)
                throw StoreError.imageWrite(message)
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: imagePNG)
            try handle.close()
            wroteImage = true
        } catch {
            if !wroteImage { unlinkat(directoryFD, fileName, 0) }
            if let error = error as? StoreError { throw error }
            throw StoreError.imageWrite(error.localizedDescription)
        }

        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        bindText(stmt, 2, fileName)
        bindText(stmt, 3, context.source.rawValue)
        bindText(stmt, 4, context.text)
        bindText(stmt, 5, domJSON)
        bindText(stmt, 6, note)
        bindText(stmt, 7, markersJSON)
        bindText(stmt, 8, context.appName)
        bindText(stmt, 9, context.windowTitle)
        bindText(stmt, 10, context.layout?.rawValue)
        bindText(stmt, 11, redactionStatus.rawValue)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            // Don't leave the PNG behind if the row didn't land.
            unlinkat(directoryFD, fileName, 0)
            throw StoreError.sql(lastErrorMessage())
        }
        let id = sqlite3_last_insert_rowid(db)

        // Retention is best-effort: the Capture is already stored, so a purge
        // failure must not fail the write.
        do { try purge(now: now) } catch { /* keep the capture; spool stays a bit long */ }

        return Capture(id: id, createdAt: now, imageFile: fileName, note: note,
                       context: context, markers: markers, redactionStatus: redactionStatus)
    }

    /// Number of Captures currently retained.
    public func count() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM captures;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sql(lastErrorMessage()) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Reads a specific local-library section, newest first. On databases from
    /// before the library migration, all captures are treated as Recent.
    public func captures(in state: CaptureLibraryState, limit: Int = 100) throws -> [Capture] {
        guard limit > 0, hasCapturesTable else { return [] }
        if !hasLibraryColumns {
            return state == .recent ? try recent(limit: limit) : []
        }
        let stmt = try prepare("SELECT \(captureColumns) FROM captures WHERE library_state = ? ORDER BY id DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, state.rawValue)
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [Capture] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(try row(stmt)) }
        return out
    }

    /// Finds captures using the deliberately small, user-visible search surface:
    /// tags, capture/pin notes, app name, and window title. It never searches
    /// OCR or DOM payloads, which can be noisy and privacy-sensitive.
    public func searchCaptures(query: String, state: CaptureLibraryState? = nil,
                               tag: String? = nil, limit: Int = 1_000) throws -> [Capture] {
        let source: [Capture]
        if let state {
            source = try captures(in: state, limit: limit)
        } else if hasLibraryColumns {
            let stmt = try prepare("SELECT \(captureColumns) FROM captures \(activeCapturePredicate) ORDER BY id DESC LIMIT ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clamping: limit))
            var captures: [Capture] = []
            while sqlite3_step(stmt) == SQLITE_ROW { captures.append(try row(stmt)) }
            source = captures
        } else {
            source = try recent(limit: limit)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.isEmpty ? nil : trimmed
        let tagNeedle = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.filter { capture in
            if let tagNeedle, !capture.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tagNeedle) == .orderedSame }) {
                return false
            }
            guard let needle else { return true }
            let fields = capture.tags + [capture.note, capture.context.appName, capture.context.windowTitle]
                .compactMap { $0 } + capture.markers.compactMap(\.note)
            return fields.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    /// Tags are derived from active captures, so removing the last assignment
    /// automatically removes the tag from suggestions without another table.
    public func activeTags(limit: Int = 1_000) throws -> [String] {
        let captures = try searchCaptures(query: "", limit: limit)
        return CaptureTag.normalize(captures.flatMap(\.tags))
    }

    /// Most recently used tags, based on the newest active Capture carrying each
    /// tag. No separate tag table or stale usage metadata is necessary.
    public func recentlyUsedActiveTags(limit: Int = 5) throws -> [String] {
        guard limit > 0 else { return [] }
        let captures = try searchCaptures(query: "", limit: 1_000)
        var seen = Set<String>()
        var result: [String] = []
        for capture in captures {
            for tag in capture.tags {
                let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(key).inserted { result.append(tag) }
                if result.count == limit { return result }
            }
        }
        return result
    }

    public func setKept(_ kept: Bool, id: Int64) throws {
        try requireCaptureWriter()
        guard hasLibraryColumns else { return }
        let stmt = try prepare("UPDATE captures SET library_state = ?, deleted_at = NULL, deleted_from_state = NULL WHERE id = ? AND library_state != 'recentlyDeleted';")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, kept ? CaptureLibraryState.kept.rawValue : CaptureLibraryState.recent.rawValue)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    public func moveToTrash(id: Int64, now: Date = Date()) throws {
        try requireCaptureWriter()
        guard hasLibraryColumns else { return }
        let stmt = try prepare("UPDATE captures SET deleted_from_state = library_state, library_state = 'recentlyDeleted', deleted_at = ? WHERE id = ? AND library_state != 'recentlyDeleted';")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    public func restore(id: Int64) throws {
        try requireCaptureWriter()
        guard hasLibraryColumns else { return }
        let stmt = try prepare("UPDATE captures SET library_state = COALESCE(deleted_from_state, 'recent'), deleted_at = NULL, deleted_from_state = NULL WHERE id = ? AND library_state = 'recentlyDeleted';")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    public func updateTags(_ tags: [String], id: Int64) throws {
        try requireCaptureWriter()
        guard hasTagsColumn else { return }
        let normalized = CaptureTag.normalize(tags)
        let json = try String(data: JSONEncoder().encode(normalized), encoding: .utf8)
        let stmt = try prepare("UPDATE captures SET tags_json = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, json)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    public func permanentlyErase(id: Int64) throws {
        try requireCaptureWriter()
        guard let capture = try capture(id: id) else { return }
        try eraseCaptureRows([id: capture.imageFile])
    }

    /// Permanently removes every Capture in Recently Deleted and its PNG.
    /// Returns the number removed so callers can report an honest result.
    @discardableResult
    public func emptyRecentlyDeleted() throws -> Int {
        try requireCaptureWriter()
        guard hasLibraryColumns else { return 0 }
        var victims: [Int64: String] = [:]
        let stmt = try prepare(
            "SELECT id, image_file FROM captures WHERE library_state = 'recentlyDeleted';"
        )
        collect(stmt, into: &victims)
        sqlite3_finalize(stmt)
        try eraseCaptureRows(victims)
        return victims.count
    }

    public func clearRecent(now: Date = Date()) throws {
        try requireCaptureWriter()
        guard hasLibraryColumns else { return }
        let stmt = try prepare("UPDATE captures SET deleted_from_state = 'recent', library_state = 'recentlyDeleted', deleted_at = ? WHERE library_state = 'recent';")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    /// Applies the configured retention immediately, used after changing the
    /// library setting rather than waiting for the next capture.
    public func applyRetention(now: Date = Date()) throws {
        try requireCaptureWriter()
        try purge(now: now)
    }

    /// Drops Captures that fall outside the retention window — older than
    /// the configured duration or beyond the newest `maxCaptures` — deleting
    /// both the row and its PNG so almost nothing durable is left on disk (ADR 0009).
    private func purge(now: Date) throws {
        var victims: [Int64: String] = [:]

        let ageThreshold = now.timeIntervalSince1970 - retention.duration.seconds
        let recentWhere = hasLibraryColumns ? "library_state = 'recent' AND " : ""
        let byAge = try prepare("SELECT id, image_file FROM captures WHERE \(recentWhere)created_at < ?;")
        sqlite3_bind_double(byAge, 1, ageThreshold)
        collect(byAge, into: &victims)
        sqlite3_finalize(byAge)

        // Everything except the newest `maxCaptures` rows.
        let byCount = try prepare("SELECT id, image_file FROM captures \(hasLibraryColumns ? "WHERE library_state = 'recent'" : "") ORDER BY id DESC LIMIT -1 OFFSET ?;")
        sqlite3_bind_int(byCount, 1, Int32(max(0, retention.maxCaptures)))
        collect(byCount, into: &victims)
        sqlite3_finalize(byCount)

        if hasLibraryColumns {
            let trashed = try prepare("SELECT id, image_file FROM captures WHERE library_state = 'recentlyDeleted' AND deleted_at < ?;")
            sqlite3_bind_double(trashed, 1, ageThreshold)
            collect(trashed, into: &victims)
            sqlite3_finalize(trashed)
        }

        try eraseCaptureRows(victims)
    }

    private func eraseCaptureRows(_ victims: [Int64: String]) throws {
        guard !victims.isEmpty else { return }

        // Treat each Capture as a cleanup unit. A refused filesystem deletion
        // rolls its row back, while earlier completed units stay deleted and
        // later ones remain untouched for a safe retry.
        for (id, file) in victims.sorted(by: { $0.key < $1.key }) {
            try exec("BEGIN IMMEDIATE;")
            do {
                let del = try prepare("DELETE FROM captures WHERE id = ?;")
                sqlite3_bind_int64(del, 1, id)
                let rc = sqlite3_step(del)
                sqlite3_finalize(del)
                guard rc == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }

                if Store.isWriterImageName(file),
                   unlinkat(directoryFD, file, 0) != 0,
                   errno != ENOENT {
                    let message = String(cString: strerror(errno))
                    throw StoreError.imageDelete("\(file): \(message)")
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    private func collect(_ stmt: OpaquePointer?, into dict: inout [Int64: String]) {
        while sqlite3_step(stmt) == SQLITE_ROW {
            dict[sqlite3_column_int64(stmt, 0)] = columnText(stmt, 1) ?? ""
        }
    }

    // MARK: - Capture requests (Hub writes, Conductor reads/clears)

    /// Inserts a pending request, or returns the existing active request. The
    /// immediate transaction makes that single-pending semantic hold across the
    /// separate Hub processes spawned by multiple MCP clients.
    @discardableResult
    public func insertRequest(requester: String = "Local MCP client", now: Date = Date()) throws -> CaptureRequest {
        try requireRequestWriter()
        let requester = Store.normalizedRequester(requester)
        try exec("BEGIN IMMEDIATE;")
        do {
            try deleteStaleRequests(now: now)

            let existing = try prepare("SELECT id, created_at, requester FROM requests ORDER BY id DESC LIMIT 1;")
            let existingRequest = sqlite3_step(existing) == SQLITE_ROW ? requestRow(existing) : nil
            sqlite3_finalize(existing)
            if let existingRequest {
                let refresh = try prepare("UPDATE requests SET created_at = ?, requester = ? WHERE id = ?;")
                sqlite3_bind_double(refresh, 1, now.timeIntervalSince1970)
                bindText(refresh, 2, requester)
                sqlite3_bind_int64(refresh, 3, existingRequest.id)
                let rc = sqlite3_step(refresh)
                sqlite3_finalize(refresh)
                guard rc == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
                try exec("COMMIT;")
                return CaptureRequest(id: existingRequest.id, createdAt: now, requester: requester)
            }

            let insert = try prepare("INSERT INTO requests (created_at, requester) VALUES (?, ?);")
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_double(insert, 1, now.timeIntervalSince1970)
            bindText(insert, 2, requester)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw StoreError.sql(lastErrorMessage())
            }
            let request = CaptureRequest(id: sqlite3_last_insert_rowid(db), createdAt: now,
                                         requester: requester)
            try exec("COMMIT;")
            return request
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Returns active requests oldest first after deleting expired rows. In v1
    /// this is at most one row because `insertRequest` coalesces duplicates.
    public func pendingRequests(now: Date = Date()) throws -> [CaptureRequest] {
        try requireRequestWriter()
        try deleteStaleRequests(now: now)
        let stmt = try prepare("SELECT id, created_at, requester FROM requests ORDER BY id ASC;")
        defer { sqlite3_finalize(stmt) }
        var requests: [CaptureRequest] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: requests.append(requestRow(stmt))
            case SQLITE_DONE: return requests
            default: throw StoreError.sql(lastErrorMessage())
            }
        }
    }

    /// Clears one request after the user dismisses its nudge.
    public func clearRequest(id: Int64) throws {
        try requireRequestWriter()
        let stmt = try prepare("DELETE FROM requests WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    /// Clears requests fulfilled by a human Capture, without swallowing a newer
    /// request that races in just after that Capture was written.
    public func clearRequests(createdThrough date: Date) throws {
        try requireRequestWriter()
        let stmt = try prepare("DELETE FROM requests WHERE created_at <= ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    private func deleteStaleRequests(now: Date) throws {
        let stmt = try prepare("DELETE FROM requests WHERE created_at < ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970 - Self.requestMaxAgeSeconds)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(lastErrorMessage()) }
    }

    private func requireRequestWriter() throws {
        guard access == .captureWriter || access == .requestWriter else {
            throw StoreError.access("request mutation requires a request writer")
        }
    }

    private func requireCaptureWriter() throws {
        guard access == .captureWriter else {
            throw StoreError.access("capture library mutation requires the Conductor capture writer")
        }
    }

    private func requestRow(_ stmt: OpaquePointer?) -> CaptureRequest {
        CaptureRequest(
            id: sqlite3_column_int64(stmt, 0),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            requester: columnText(stmt, 2) ?? "Local MCP client"
        )
    }

    // MARK: - Reader (Hub)

    /// The current journal mode (e.g. "wal"). Used to confirm the writer put the
    /// Store into WAL so readers can coexist.
    public func journalMode() throws -> String {
        let stmt = try prepare("PRAGMA journal_mode;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sql(lastErrorMessage()) }
        return columnText(stmt, 0) ?? ""
    }

    /// The id of the most recent Capture, or nil if the Store is empty.
    public func latestId() throws -> Int64? {
        try latest()?.id
    }

    /// The SELECT column list shared by every Capture reader. Optional columns are
    /// appended only when the (possibly pre-migration) database has them, in the
    /// fixed order `row(_:)` decodes; the two are kept in lockstep.
    private var captureColumns: String {
        var cols = ["id", "created_at", "image_file", "source", "text", "dom_json", "note"]
        if hasMarkersColumn { cols.append("markers_json") }
        if hasTargetColumns { cols.append("app_name"); cols.append("window_title") }
        if hasLayoutColumn { cols.append("layout") }
        if hasRedactionStatusColumn { cols.append("redaction_status") }
        if hasTagsColumn { cols.append("tags_json") }
        if hasLibraryColumns {
            cols.append("library_state")
            cols.append("deleted_at")
            cols.append("deleted_from_state")
        }
        return cols.joined(separator: ", ")
    }

    private var activeCapturePredicate: String {
        hasLibraryColumns ? "WHERE library_state != 'recentlyDeleted'" : ""
    }

    /// The most recent Capture, or nil if the Store is empty.
    public func latest() throws -> Capture? {
        guard hasCapturesTable else { return nil }
        let stmt = try prepare("SELECT \(captureColumns) FROM captures \(activeCapturePredicate) ORDER BY id DESC LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return try row(stmt)
        case SQLITE_DONE: return nil
        default: throw StoreError.sql(lastErrorMessage())
        }
    }

    /// The Capture with `id`, or nil if it is not (or no longer) in the spool.
    /// A missing id is the ephemeral-purge case, not an error (SPE-558).
    public func capture(id: Int64) throws -> Capture? {
        guard hasCapturesTable else { return nil }
        let stmt = try prepare("SELECT \(captureColumns) FROM captures WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return try row(stmt)
        case SQLITE_DONE: return nil
        default: throw StoreError.sql(lastErrorMessage())
        }
    }

    /// The retained Captures, newest first, capped at `limit`. Used by the Hub to
    /// let an Agent orient over the spool before pulling image bytes (SPE-558).
    /// The result is naturally bounded by retention, but `limit` guards against a
    /// caller asking for more than it can use.
    public func recent(limit: Int) throws -> [Capture] {
        guard limit > 0, hasCapturesTable else { return [] }
        let stmt = try prepare("SELECT \(captureColumns) FROM captures \(activeCapturePredicate) ORDER BY id DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(clamping: limit))
        var out: [Capture] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(try row(stmt))
            case SQLITE_DONE: return out
            default: throw StoreError.sql(lastErrorMessage())
            }
        }
    }

    /// The most recent Capture only if it is newer than `afterId`. Returns nil
    /// when the Store is empty or the latest Capture's id is not greater than
    /// `afterId` — this is how an Agent skips what it has already seen (ADR 0005).
    public func latest(afterId: Int64?) throws -> Capture? {
        guard let capture = try latest() else { return nil }
        if let afterId, capture.id <= afterId { return nil }
        return capture
    }

    /// Runs `body` inside a single read transaction, giving it a stable snapshot
    /// of the Store even if a writer commits concurrently (WAL). Useful when more
    /// than one read must agree, and to hold a snapshot open.
    public func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Reads the PNG bytes for a Capture.
    public func imageData(for capture: Capture) throws -> Data {
        guard Store.isWriterImageName(capture.imageFile) else {
            throw StoreError.imageRead("invalid capture image filename")
        }
        let fd = openat(directoryFD, capture.imageFile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.imageRead(Store.systemError()) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw StoreError.imageRead(Store.systemError()) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.imageRead("capture image is not a regular file")
        }
        guard info.st_uid == getuid() else {
            throw StoreError.imageRead("capture image has the wrong owner")
        }
        guard info.st_mode & 0o777 == 0o600 else {
            throw StoreError.imageRead("capture image has unsafe permissions")
        }
        guard info.st_size >= off_t(Self.pngMagic.count),
              info.st_size <= off_t(Self.maximumImageBytes) else {
            throw StoreError.imageRead("capture image size is outside the allowed range")
        }

        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.read(upToCount: Self.maximumImageBytes + 1) ?? Data()
            guard data.count == Int(info.st_size), data.count <= Self.maximumImageBytes else {
                throw StoreError.imageRead("capture image changed while being read")
            }
            guard data.starts(with: Self.pngMagic) else {
                throw StoreError.imageRead("capture image is not a PNG")
            }
            return data
        } catch {
            if let error = error as? StoreError { throw error }
            throw StoreError.imageRead(error.localizedDescription)
        }
    }

    // MARK: - Filesystem hardening

    private static func openStoreDirectory(_ directory: URL) throws -> Int32 {
        // O_NOFOLLOW on the leaf only rejects a symlinked final component. A
        // LASSO_STORE_DIR override pointing through a shared directory could have a
        // symlinked *intermediate* component swapped in to redirect the whole store
        // (and its fchmod calls) elsewhere. Canonicalize with realpath (system
        // symlinks like /var -> /private/var resolve to real dirs) and verify every
        // ancestor is owned by root or the current user and not group/other-writable,
        // so no untrusted party could have planted a redirecting symlink in the chain.
        try verifyAncestorChain(directory)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.access("unsafe store directory: \(systemError())") }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            throw StoreError.access("could not inspect store directory: \(systemError())")
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            close(fd)
            throw StoreError.access("store directory must be a non-symlink directory owned by the current user")
        }
        guard fchmod(fd, 0o700) == 0 else {
            close(fd)
            throw StoreError.access("could not secure store directory: \(systemError())")
        }
        return fd
    }

    /// Rejects the store directory if any ancestor of its canonical (symlink-free)
    /// path is owned by another user or is group/other-writable — the only way an
    /// untrusted party could plant a symlink to redirect the store. System symlinks
    /// (e.g. /var -> /private/var) are resolved by realpath and thus tolerated.
    private static func verifyAncestorChain(_ directory: URL) throws {
        guard let resolved = realpath(directory.path, nil) else {
            throw StoreError.access("could not resolve store directory: \(systemError())")
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        let uid = getuid()
        // Build ancestor paths: "/", "/a", "/a/b", ... up to and including the dir.
        var prefix = ""
        var paths = ["/"]
        for component in canonical.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            paths.append(prefix)
        }
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0 else {
                throw StoreError.access("could not inspect store ancestor \(path): \(systemError())")
            }
            guard info.st_uid == 0 || info.st_uid == uid else {
                throw StoreError.access("store directory ancestor \(path) is owned by another user")
            }
            // Reject group- or other-writable ancestors (unless the sticky bit is set,
            // which makes shared dirs like /tmp safe against cross-user rename/symlink).
            let writableByOthers = (info.st_mode & S_IWGRP) != 0 || (info.st_mode & S_IWOTH) != 0
            let sticky = (info.st_mode & S_ISVTX) != 0
            if writableByOthers && !sticky {
                throw StoreError.access("store directory ancestor \(path) is writable by other users")
            }
        }
    }

    private static func secureSQLiteFile(directoryFD: Int32, name: String,
                                         create: Bool = false) throws {
        var flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        if create { flags |= O_CREAT }
        let fd = openat(directoryFD, name, flags, 0o600)
        if fd < 0 {
            if !create && errno == ENOENT { return }
            throw StoreError.access("unsafe \(name): \(systemError())")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() else {
            throw StoreError.access("\(name) must be a regular file owned by the current user")
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw StoreError.access("could not secure \(name): \(systemError())")
        }
    }

    private func secureExistingStoreFiles() throws {
        try Store.secureSQLiteFile(directoryFD: directoryFD, name: "store.sqlite3")
        try Store.secureSQLiteFile(directoryFD: directoryFD, name: "store.sqlite3-wal")
        try Store.secureSQLiteFile(directoryFD: directoryFD, name: "store.sqlite3-shm")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where Store.isWriterImageName(name) {
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw StoreError.access("unsafe capture image: \(Store.systemError())") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid() else {
                throw StoreError.access("capture images must be regular files owned by the current user")
            }
            guard fchmod(fd, 0o600) == 0 else {
                throw StoreError.access("could not secure capture image: \(Store.systemError())")
            }
        }
    }

    private static func isWriterImageName(_ name: String) -> Bool {
        guard name.count == 40, name.hasSuffix(".png"),
              !name.contains("/"), !name.contains("\\") else { return false }
        let uuidText = String(name.dropLast(4))
        guard let uuid = UUID(uuidString: uuidText) else { return false }
        return uuid.uuidString + ".png" == name
    }

    private static func normalizedRequester(_ requester: String) -> String {
        let visible = requester.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(visible)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Local MCP client" : String(trimmed.prefix(80))
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }

    // MARK: - Row decoding

    private func row(_ stmt: OpaquePointer?) throws -> Capture {
        let id = sqlite3_column_int64(stmt, 0)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let imageFile = columnText(stmt, 2) ?? ""
        let source = ContextSource(rawValue: columnText(stmt, 3) ?? "none") ?? .none
        let text = columnText(stmt, 4)
        let domJSON = columnText(stmt, 5)
        let note = columnText(stmt, 6)
        let dom = try domJSON.map { try decodeDOM($0) }

        // Optional columns follow the fixed 0...6 prefix in the same order
        // `captureColumns` appends them; advance the index only for those present.
        var idx: Int32 = 7
        var markers: [Marker] = []
        if hasMarkersColumn {
            markers = try columnText(stmt, idx).map { try decodeMarkers($0) } ?? []
            idx += 1
        }
        var appName: String?
        var windowTitle: String?
        if hasTargetColumns {
            appName = columnText(stmt, idx); idx += 1
            windowTitle = columnText(stmt, idx); idx += 1
        }
        var layout: TextLayout?
        if hasLayoutColumn {
            layout = columnText(stmt, idx).flatMap(TextLayout.init(rawValue:)); idx += 1
        }
        var redactionStatus = RedactionStatus.none
        if hasRedactionStatusColumn {
            redactionStatus = columnText(stmt, idx).flatMap(RedactionStatus.init(rawValue:)) ?? .none; idx += 1
        }
        var tags: [String] = []
        if hasTagsColumn {
            tags = try columnText(stmt, idx).map { try decodeTags($0) } ?? []; idx += 1
        }
        var libraryState = CaptureLibraryState.recent
        var deletedAt: Date?
        var deletedFromState: CaptureLibraryState?
        if hasLibraryColumns {
            libraryState = columnText(stmt, idx).flatMap(CaptureLibraryState.init(rawValue:)) ?? .recent; idx += 1
            if sqlite3_column_type(stmt, idx) != SQLITE_NULL {
                deletedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, idx))
            }
            idx += 1
            deletedFromState = columnText(stmt, idx).flatMap(CaptureLibraryState.init(rawValue:))
        }
        let context = CaptureContext(source: source, text: text, dom: dom,
                                     appName: appName, windowTitle: windowTitle, layout: layout)
        return Capture(id: id, createdAt: createdAt, imageFile: imageFile, note: note,
                       context: context, markers: markers, redactionStatus: redactionStatus,
                       tags: tags, libraryState: libraryState, deletedAt: deletedAt,
                       deletedFromState: deletedFromState)
    }

    // MARK: - DOM (de)serialization

    private func encodeDOM(_ dom: DOMFingerprint) throws -> String {
        let data = try JSONEncoder().encode(dom)
        guard let s = String(data: data, encoding: .utf8) else {
            throw StoreError.sql("dom encode failed")
        }
        return s
    }

    private func decodeDOM(_ json: String) throws -> DOMFingerprint {
        guard let data = json.data(using: .utf8) else {
            throw StoreError.sql("dom decode failed")
        }
        return try JSONDecoder().decode(DOMFingerprint.self, from: data)
    }

    // MARK: - Marker (de)serialization

    private func encodeMarkers(_ markers: [Marker]) throws -> String {
        let data = try JSONEncoder().encode(markers)
        guard let s = String(data: data, encoding: .utf8) else {
            throw StoreError.sql("markers encode failed")
        }
        return s
    }

    private func decodeMarkers(_ json: String) throws -> [Marker] {
        guard let data = json.data(using: .utf8) else {
            throw StoreError.sql("markers decode failed")
        }
        return try JSONDecoder().decode([Marker].self, from: data)
    }

    private func decodeTags(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { throw StoreError.sql("tags decode failed") }
        return try JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        try Store.exec(db, sql)
    }

    /// Runs a statement with no results against `db`. Static so it can run during
    /// `init` before `self` is fully initialized.
    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? (db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(lastErrorMessage())
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func lastErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}
