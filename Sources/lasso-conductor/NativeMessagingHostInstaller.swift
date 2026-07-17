#if os(macOS)
import Foundation
import LassoConductorCore

/// Registers the bundled relay host for the current user. The manifest is
/// regenerated on launch so moving Lasso.app never leaves Chrome pointing to an
/// old executable path.
enum NativeMessagingHostInstaller {
    static func install() throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw InstallerError.missingExecutable
        }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let manifest = support.appendingPathComponent("\(NativeMessagingHostManifest.hostName).json")
        let relayPath = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("lasso-relay-host")
            .path
        try NativeMessagingHostManifest.data(executablePath: relayPath)
            .write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }

    private enum InstallerError: LocalizedError {
        case missingExecutable

        var errorDescription: String? {
            switch self {
            case .missingExecutable: return "Lasso could not locate its bundled executable."
            }
        }
    }
}
#endif
