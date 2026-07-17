import Foundation

/// Locates the unpacked browser extension bundled with Lasso, or the copy in a
/// development checkout. Keeping the lookup platform-free makes distribution
/// packaging testable without launching the AppKit onboarding window.
public enum ExtensionFolderLocator {
    public enum OpenResult: Equatable {
        case opened
        case folderMissing
        case workspaceUnavailable
    }

    public static func locate(resourceURL: URL?, executableURL: URL?,
                              fileManager: FileManager = .default) -> URL? {
        if let resourceURL {
            let bundled = resourceURL.appendingPathComponent("extension", isDirectory: true)
            if containsManifest(bundled, fileManager: fileManager) {
                return bundled
            }
        }

        guard let executableURL else { return nil }
        var directory = executableURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("extension", isDirectory: true)
            if containsManifest(candidate, fileManager: fileManager) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// Opens a discovered extension directory through the supplied workspace
    /// action. The AppKit caller supplies `NSWorkspace.open`; this seam keeps
    /// the user-visible success and failure behavior unit-testable.
    public static func open(_ folderURL: URL?, using workspaceOpen: (URL) -> Bool) -> OpenResult {
        guard let folderURL else { return .folderMissing }
        return workspaceOpen(folderURL) ? .opened : .workspaceUnavailable
    }

    private static func containsManifest(_ directory: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
    }
}
