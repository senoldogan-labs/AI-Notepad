// swift-tools-version: 6.2
import PackageDescription

// The shared language of the iPhone app and the Apple Watch app (WatchConnectivity messages, the snapshot, pure
// helpers). Foundation only, so it builds for watchOS without the core package's WhisperKit graph.
let package = Package(
    name: "AINotepadWatchLink",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v26)],
    products: [
        .library(name: "AINotepadWatchLink", targets: ["AINotepadWatchLink"]),
    ],
    targets: [
        .target(name: "AINotepadWatchLink"),
        .testTarget(name: "AINotepadWatchLinkTests", dependencies: ["AINotepadWatchLink"]),
    ]
)
