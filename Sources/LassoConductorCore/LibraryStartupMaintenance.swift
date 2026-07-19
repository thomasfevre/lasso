import Foundation
import LassoCore

public struct LibraryStartupMaintenanceError: Error, LocalizedError {
    public let failures: [String]

    public var errorDescription: String? {
        "Library maintenance failed: \(failures.joined(separator: "; "))"
    }
}

/// Runs the library maintenance that must happen even when no new capture is
/// created and the retention setting has not changed.
public enum LibraryStartupMaintenance {
    public static func run(
        store: Store,
        now: Date = Date(),
        abandonedShareCleanup: () throws -> Void = {
            try TemporaryArtifactLease.removeAbandonedArtifacts()
        }
    ) throws {
        var failures: [String] = []
        do {
            try store.applyRetention(now: now)
        } catch {
            failures.append(String(describing: error))
        }
        do {
            try store.removeOrphanedCaptureImages()
        } catch {
            failures.append(String(describing: error))
        }
        do {
            try abandonedShareCleanup()
        } catch {
            failures.append(String(describing: error))
        }
        if !failures.isEmpty {
            throw LibraryStartupMaintenanceError(failures: failures)
        }
    }
}
