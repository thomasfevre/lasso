import Foundation

/// The MCP clients Lasso ships copy-paste registration snippets for (ADR 0005).
/// Every client runs the same `lasso-mcp` binary over stdio; only the config
/// format differs (JSON for Claude Code / Cursor, TOML for Codex).
public enum RegistrationClient: String, CaseIterable {
    case claude
    case cursor
    case codex

    /// Human-facing product name, for pickers and labels.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        }
    }
}

/// Renders the registration snippet for a client, pointing at a concrete binary
/// path. Kept pure so the exact wording is unit-testable and reused by the
/// onboarding flow (SPE-552).
public enum RegistrationSnippet {
    /// Escapes a path for embedding inside a double-quoted JSON or TOML string,
    /// so a path containing a backslash or quote still yields valid config.
    private static func escaped(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Quotes one shell argument for copy-paste into a POSIX shell. Config-file
    /// escaping is intentionally separate because JSON/TOML use different rules.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func text(for client: RegistrationClient, binaryPath: String) -> String {
        let path = escaped(binaryPath)
        switch client {
        case .claude:
            let cliPath = shellQuoted(binaryPath)
            return """
            Claude Code: run this command:
                claude mcp add lasso \(cliPath)

            or add to your MCP config JSON:
                {
                  "mcpServers": {
                    "lasso": { "command": "\(path)" }
                  }
                }
            """
        case .cursor:
            return """
            Cursor: add this to ~/.cursor/mcp.json:
                {
                  "mcpServers": {
                    "lasso": { "command": "\(path)" }
                  }
                }
            """
        case .codex:
            return """
            Codex: add this to ~/.codex/config.toml:
                [mcp_servers.lasso]
                command = "\(path)"

            Note: Codex requires the binary on your PATH or an absolute path
            (the absolute path above satisfies this).
            """
        }
    }

    /// A combined snippet for every client, for the onboarding step.
    public static func allClients(binaryPath: String) -> String {
        RegistrationClient.allCases
            .map { text(for: $0, binaryPath: binaryPath) }
            .joined(separator: "\n\n")
    }
}
