import Foundation

/// Resolves the path to advertise in a registration snippet from how the binary
/// was invoked. An absolute `argv[0]` is used as-is; a relative one with a slash
/// is resolved against the cwd; a bare name (PATH invocation) is looked up on
/// PATH. Pure and injectable so it is unit-testable.
public enum BinaryPathResolver {
    public static func resolve(
        arg0: String,
        cwd: String,
        pathEnv: String?,
        fileExists: (String) -> Bool
    ) -> String {
        if arg0.hasPrefix("/") { return arg0 }
        if arg0.contains("/") {
            return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).standardizedFileURL.path
        }
        // Bare name: find it on PATH, otherwise fall back to the bare name (the
        // snippet then relies on PATH, and the user can pass an explicit path).
        for dir in (pathEnv ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(arg0).path
            if fileExists(candidate) { return candidate }
        }
        return arg0
    }
}
