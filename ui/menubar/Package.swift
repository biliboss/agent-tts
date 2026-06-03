// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// AgentTTSMenubar — macOS menubar UI for the agent-tts daemon.
//
// Talks the same UNIX-socket TSV protocol as the CLI (`src/client.zig`)
// and the MCP shim (`src/mcp.zig`). The daemon is unchanged; this is a
// third client on the same wire.
//
// Targets:
//   AgentTTSMenubarCore   — pure library (SocketClient, VoiceCatalog, ...)
//                            so it can be imported by tests + the check exec.
//   AgentTTSMenubar       — the app entry (NSStatusItem + SwiftUI popover).
//   SocketProtocolCheck   — standalone smoke runner; works on toolchains
//                            without XCTest (Command Line Tools only).
//   AgentTTSMenubarTests  — XCTest target; compiles a no-op under non-Xcode
//                            toolchains via `canImport(XCTest)` guard.
//
// Build:   cd ui/menubar && swift build -c release
// Smoke:   swift run -c release SocketProtocolCheck
//
import PackageDescription

let package = Package(
    name: "AgentTTSMenubar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentTTSMenubar", targets: ["AgentTTSMenubar"]),
        .executable(name: "SocketProtocolCheck", targets: ["SocketProtocolCheck"]),
        .library(name: "AgentTTSMenubarCore", targets: ["AgentTTSMenubarCore"]),
    ],
    targets: [
        .target(
            name: "AgentTTSMenubarCore",
            path: "Sources/AgentTTSMenubarCore"
        ),
        .executableTarget(
            name: "AgentTTSMenubar",
            dependencies: ["AgentTTSMenubarCore"],
            path: "Sources/AgentTTSMenubar"
        ),
        .executableTarget(
            name: "SocketProtocolCheck",
            dependencies: ["AgentTTSMenubarCore"],
            path: "Sources/SocketProtocolCheck"
        ),
        .testTarget(
            name: "AgentTTSMenubarTests",
            dependencies: ["AgentTTSMenubarCore"],
            path: "Tests/AgentTTSMenubarTests"
        ),
    ]
)
