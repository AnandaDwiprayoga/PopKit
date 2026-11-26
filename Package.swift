// swift-tools-version:5.9
// Build the app with ./build.sh (wraps the binary in PopKit.app). `swift build`
// alone gives a bare binary without Info.plist, so there is no menu bar mode.
import PackageDescription

let package = Package(
    name: "PopKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PopKitCore", targets: ["PopKitCore"]),
        .executable(name: "PopKit", targets: ["PopKit"]),
    ],
    targets: [
        // No AppKit UI here, so it stays unit-testable.
        .target(name: "PopKitCore", path: "Sources/PopKitCore"),
        .executableTarget(
            name: "PopKit",
            dependencies: ["PopKitCore"],
            path: "Sources/PopKit"
        ),
        .testTarget(
            name: "PopKitCoreTests",
            dependencies: ["PopKitCore"],
            path: "Tests/PopKitCoreTests"
        ),
    ]
)
