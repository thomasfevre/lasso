import XCTest
@testable import LassoHub

// SPE-550: the copy-paste registration snippets each client needs.
final class RegistrationSnippetTests: XCTestCase {
    private let path = "/Applications/Lasso.app/Contents/MacOS/lasso-mcp"

    func testClaudeSnippetUsesBinaryPathAndMcpServers() {
        let s = RegistrationSnippet.text(for: .claude, binaryPath: path)
        XCTAssertTrue(s.contains(path))
        XCTAssertTrue(s.contains("mcpServers"))
        XCTAssertTrue(s.contains("claude mcp add lasso"))
    }

    func testCursorSnippetUsesMcpJson() {
        let s = RegistrationSnippet.text(for: .cursor, binaryPath: path)
        XCTAssertTrue(s.contains(path))
        XCTAssertTrue(s.contains("~/.cursor/mcp.json"))
        XCTAssertTrue(s.contains("mcpServers"))
    }

    func testCodexSnippetUsesTomlAndDocumentsPathRequirement() {
        let s = RegistrationSnippet.text(for: .codex, binaryPath: path)
        XCTAssertTrue(s.contains(path))
        XCTAssertTrue(s.contains("[mcp_servers.lasso]"))
        XCTAssertTrue(s.contains("config.toml"))
        // The Codex PATH / absolute-path gotcha must be spelled out (ADR 0005).
        XCTAssertTrue(s.contains("PATH"))
    }

    func testPathWithQuoteIsEscaped() {
        let s = RegistrationSnippet.text(for: .claude, binaryPath: #"/weird/"q"/lasso-mcp"#)
        XCTAssertTrue(s.contains(#"claude mcp add lasso '/weird/"q"/lasso-mcp'"#))
        XCTAssertTrue(s.contains(#""command": "/weird/\"q\"/lasso-mcp""#))
    }

    func testClaudeCLIPathIsShellQuoted() {
        let path = "/tmp/`touch injected`/$(touch also-injected)/lasso-mcp"
        let s = RegistrationSnippet.text(for: .claude, binaryPath: path)
        XCTAssertTrue(s.contains("claude mcp add lasso '\(path)'"))
    }

    func testClaudeCLIPathEscapesEmbeddedSingleQuote() {
        let s = RegistrationSnippet.text(for: .claude, binaryPath: "/tmp/it's/lasso-mcp")
        XCTAssertTrue(s.contains(#"claude mcp add lasso '/tmp/it'\''s/lasso-mcp'"#))
    }

    func testAllClientsCoversEveryClient() {
        let all = RegistrationSnippet.allClients(binaryPath: path)
        XCTAssertTrue(all.contains("Claude Code"))
        XCTAssertTrue(all.contains("Cursor"))
        XCTAssertTrue(all.contains("Codex"))
    }
}
