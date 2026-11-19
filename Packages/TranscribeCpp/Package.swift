// swift-tools-version: 5.9
import PackageDescription

// Swift bindings for transcribe.cpp (https://github.com/handy-computer/transcribe.cpp), the speech
// engine. The Swift sources are copied unchanged from `bindings/swift` at tag v0.4.2; the
// native code is that release's prebuilt framework. To update: copy the new tag's sources and change
// the url and checksum together.
let package = Package(
    name: "TranscribeCpp",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TranscribeCpp", targets: ["TranscribeCpp"])],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.2/TranscribeCpp.xcframework.zip",
            checksum: "650a42ee7836558d3047f328078be2b8a8d4c6e9f6a0a3f4ea145481ad1c1a86"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            linkerSettings: [
                .linkedLibrary("c++"), .linkedLibrary("z"),
                .linkedFramework("Accelerate"), .linkedFramework("Foundation"),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
