import Foundation

/// A user-selected home for the whole Lasso library. This is deliberately a
/// shared suite rather than an app-local default: the Conductor, MCP server and
/// native host must resolve the same Capture store.
public enum StoreLocationPreference {
    private static let suiteName = "dev.lasso.conductor"
    private static let directoryKey = "LassoStoreDirectory"

    public static var configuredDirectory: URL? {
        guard let path = UserDefaults(suiteName: suiteName)?.string(forKey: directoryKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func setConfiguredDirectory(_ directory: URL?) {
        let defaults = UserDefaults(suiteName: suiteName)
        if let directory {
            defaults?.set(directory.standardizedFileURL.path, forKey: directoryKey)
        } else {
            defaults?.removeObject(forKey: directoryKey)
        }
        // The Chrome native host is a separate process and can be launched
        // immediately after this action, so make the shared domain visible now.
        defaults?.synchronize()
    }
}

/// Moves the SQLite database and its image files as one directory, preserving
/// the invariant that a Capture row and its PNG always live together.
public enum StoreLocationMigration {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case destinationAlreadyContainsFiles
        case destinationInsideSource
        case destinationOnAnotherVolume

        public var errorDescription: String? {
            switch self {
            case .destinationAlreadyContainsFiles:
                return "The selected Lasso folder already contains files. Choose another folder."
            case .destinationInsideSource:
                return "Choose a folder outside the current Lasso library."
            case .destinationOnAnotherVolume:
                return "Choose a folder on the same disk as the current Lasso library."
            }
        }
    }

    /// The user picks a parent folder; Lasso owns a single child directory in it
    /// so it never mixes private screenshots with unrelated personal files.
    public static func libraryDirectory(in parentDirectory: URL) -> URL {
        parentDirectory.standardizedFileURL.appendingPathComponent("Lasso", isDirectory: true)
    }

    public static func moveLibrary(from source: URL, to destination: URL,
                                   fileManager: FileManager = .default) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source != destination else { return }
        guard !destination.path.hasPrefix(source.path + "/") else {
            throw Error.destinationInsideSource
        }

        let destinationParent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
            guard contents.isEmpty else { throw Error.destinationAlreadyContainsFiles }
            try fileManager.removeItem(at: destination)
        }

        guard fileManager.fileExists(atPath: source.path) else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            return
        }

        // The running app, MCP process and browser relay may all have open file
        // descriptors in this directory. A same-volume rename preserves those
        // descriptors atomically; a cross-volume copy of a live SQLite/WAL
        // store would not be safe.
        let sourceVolume = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? AnyHashable
        let destinationVolume = try destinationParent.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? AnyHashable
        guard let sourceVolume, sourceVolume == destinationVolume else {
            throw Error.destinationOnAnotherVolume
        }
        try fileManager.moveItem(at: source, to: destination)
    }
}
