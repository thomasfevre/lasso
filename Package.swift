// swift-tools-version:5.9
import PackageDescription

// Lasso — local, open-source tool that captures on-screen spatial context and
// exposes it to a coding agent over MCP. See SPE-543 for the spec.
//
// `LassoCore` is the shared contract: the Capture model and the Store. Both the
// Hub (`lasso-mcp`, reader) and the macOS Conductor (writer, added later) import
// it so the versioned Capture contract lives in exactly one place (ADR 0004).
// `LassoHub` is the MCP server logic (kept in a library so it is unit-testable);
// the `lasso-mcp` executable is a thin stdio wrapper over it.
// The Conductor (`lasso-conductor`, SPE-545) is the macOS writer: global hotkey,
// full-screen Overlay to capture a Gesture, and a screenshot written to the Store
// via `LassoCore`. Its AppKit / ScreenCaptureKit code is guarded by `#if os(macOS)`
// so the package (and every other target) still builds on Linux, where the
// executable compiles to a stub. `platforms` only sets the macOS floor and is
// ignored on Linux; SCScreenshotManager's rect capture needs macOS 14.
let package = Package(
    name: "Lasso",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LassoCore", targets: ["LassoCore"]),
        .library(name: "LassoHub", targets: ["LassoHub"]),
        .library(name: "LassoConductorCore", targets: ["LassoConductorCore"]),
        .executable(name: "lasso-mcp", targets: ["lasso-mcp"]),
        .executable(name: "lasso-seed", targets: ["lasso-seed"]),
        .executable(name: "lasso-conductor", targets: ["lasso-conductor"]),
        .executable(name: "lasso-relay-host", targets: ["lasso-relay-host"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "LassoCore", dependencies: ["CSQLite"]),
        .target(name: "LassoHub", dependencies: ["LassoCore"]),
        // Shared, testable Conductor logic. Platform-neutral routing, relay, and
        // lifecycle seams build everywhere; macOS rendering helpers are guarded
        // with `#if os(macOS)` so the package still builds on other platforms.
        .target(name: "LassoConductorCore", dependencies: ["LassoCore"]),
        .executableTarget(name: "lasso-mcp", dependencies: ["LassoHub"]),
        .executableTarget(name: "lasso-seed", dependencies: ["LassoCore"]),
        .executableTarget(name: "lasso-relay-host", dependencies: ["LassoCore"]),
        .executableTarget(name: "lasso-conductor",
                          dependencies: ["LassoCore", "LassoConductorCore", "LassoHub"],
                          linkerSettings: [.linkedFramework("Security", .when(platforms: [.macOS]))]),
        .testTarget(name: "LassoCoreTests", dependencies: ["LassoCore"]),
        .testTarget(name: "LassoHubTests", dependencies: ["LassoHub", "LassoCore"]),
        .testTarget(name: "LassoConductorCoreTests", dependencies: ["LassoConductorCore", "LassoCore"]),
    ]
)
