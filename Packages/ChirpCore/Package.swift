// swift-tools-version: 6.2
import PackageDescription

// Pure logic and storage: the Personal Language Engine, the library, and text rules.
// No ML dependencies, so `swift test` here is fast.
let package = Package(
    name: "ChirpCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ChirpCore", targets: ["ChirpCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "ChirpCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore"]),
    ]
)
