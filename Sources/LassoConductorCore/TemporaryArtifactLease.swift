import Foundation

/// Owns a temporary export until the system sharing service finishes with it.
public final class TemporaryArtifactLease {
    public static let abandonedArtifactAge: TimeInterval = 24 * 60 * 60
    public static let artifactNamePrefix = "Lasso export "
    public let url: URL
    private let removeItem: (URL) throws -> Void
    private var released = false

    public init(
        url: URL,
        removeItem: @escaping (URL) throws -> Void = FileManager.default.removeItem(at:)
    ) {
        self.url = url
        self.removeItem = removeItem
    }

    /// Returns true only after the artifact is gone. A failed removal remains
    /// retryable so a transient sharing-service or filesystem condition cannot
    /// turn the archive into a permanent leak.
    @discardableResult
    public func release() -> Bool {
        guard !released else { return true }
        do {
            try removeItem(url)
            released = true
            return true
        } catch CocoaError.fileNoSuchFile {
            released = true
            return true
        } catch {
            return false
        }
    }

    deinit {
        release()
    }

    public static func shareDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("dev.lasso.share", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// Removes only old Lasso ZIPs from the dedicated share directory. Current
    /// picker sessions remain untouched, and unrelated temporary files are never
    /// considered.
    @discardableResult
    public static func removeAbandonedArtifacts(
        in suppliedDirectory: URL? = nil,
        olderThan minimumAge: TimeInterval = abandonedArtifactAge,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Int {
        let directory = try suppliedDirectory ?? shareDirectory(fileManager: fileManager)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for url in urls where url.lastPathComponent.hasPrefix(artifactNamePrefix) {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ])
            let isArchive = values.isRegularFile == true && url.pathExtension.lowercased() == "zip"
            let isStagingDirectory = values.isDirectory == true
            guard isArchive || isStagingDirectory,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= minimumAge else { continue }
            try fileManager.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}
