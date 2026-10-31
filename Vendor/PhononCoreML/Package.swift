// swift-tools-version: 6.0
// Library-only vendoring; Transcriber remains availability-gated for macOS 14 hosts.
import PackageDescription

let package = Package(
    name: "PhononCoreML",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PhononCoreML", targets: ["PhononCoreML"])],
    targets: [
        .binaryTarget(name: "PhononTDT", path: "Binaries/PhononTDT.xcframework"),
        .target(name: "PilotTDT", dependencies: ["PhononTDT"],
                linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "PhononCoreML", dependencies: ["PilotTDT"], path: "Sources/PhononCoreML"),
        .testTarget(name: "PhononCoreMLTests", dependencies: ["PhononCoreML", "PilotTDT"])
    ],
    cxxLanguageStandard: .cxx17
)
