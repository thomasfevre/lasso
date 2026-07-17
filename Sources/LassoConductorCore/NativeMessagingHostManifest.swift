import Foundation

/// The Chrome Native Messaging manifest for Lasso's optional browser extension.
/// Kept free of AppKit so its exact wire format is covered by unit tests.
public enum NativeMessagingHostManifest {
    public static let hostName = "xyz.allez.lasso.host"
    public static let extensionID = "onhdnknhpacnkhanhnhgnfgofebpkcmn"

    public static func data(executablePath: String) throws -> Data {
        let value: [String: Any] = [
            "name": hostName,
            "description": "Lasso extension relay",
            "path": executablePath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }
}
