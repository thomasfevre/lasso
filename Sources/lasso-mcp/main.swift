import Foundation
import LassoHub

// The Hub: a thin stdio MCP server that reads Captures and may write only the
// separate requests table. One is spawned per Agent (ADR 0005 / 0012). It never
// writes a Capture or triggers the Conductor's Overlay.
//
// A `register` subcommand prints the copy-paste MCP registration snippet for a
// client (ADR 0005 / SPE-550), pointing at this binary's path:
//     lasso-mcp register claude|cursor|codex [binary-path]
// With no subcommand it runs the server.

let arguments = CommandLine.arguments

func resolvedBinaryPath() -> String {
    BinaryPathResolver.resolve(
        arg0: arguments.first ?? "lasso-mcp",
        cwd: FileManager.default.currentDirectoryPath,
        pathEnv: ProcessInfo.processInfo.environment["PATH"],
        fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
    )
}

if arguments.count >= 2, arguments[1] == "register" {
    let clientName = arguments.count >= 3 ? arguments[2] : ""
    guard let client = RegistrationClient(rawValue: clientName) else {
        let names = RegistrationClient.allCases.map(\.rawValue).joined(separator: "|")
        FileHandle.standardError.write(Data("usage: lasso-mcp register \(names) [binary-path]\n".utf8))
        exit(2)
    }
    let binaryPath = arguments.count >= 4 ? arguments[3] : resolvedBinaryPath()
    print(RegistrationSnippet.text(for: client, binaryPath: binaryPath))
    exit(0)
}

MCPServer().run()
