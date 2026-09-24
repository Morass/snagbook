// swift-tools-version: 5.9
import PackageDescription
import Foundation

// SNAGBOOK_CORE_ONLY=1 builds just the platform-neutral core and its tests, which is how
// the core is tested on Linux. The app itself is macOS only.
let coreOnly = ProcessInfo.processInfo.environment["SNAGBOOK_CORE_ONLY"] != nil

var targets: [Target] = [
    .target(name: "SnagbookCore", path: "Sources/SnagbookCore"),
    .testTarget(name: "SnagbookCoreTests", dependencies: ["SnagbookCore"], path: "Tests/SnagbookCoreTests"),
]
var dependencies: [Package.Dependency] = []

if !coreOnly {
    dependencies.append(.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.10.0"))
    targets += [
        .target(name: "SnagbookRender", dependencies: ["SnagbookCore"], path: "Sources/SnagbookRender"),
        .executableTarget(
            name: "Snagbook",
            dependencies: ["SnagbookCore", "SnagbookRender", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")],
            path: "Sources/Snagbook",
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "SnagbookRenderTests", dependencies: ["SnagbookRender"], path: "Tests/SnagbookRenderTests"),
    ]
}

let package = Package(
    name: "Snagbook",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: targets
)
