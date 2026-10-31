// swift-tools-version: 6.2
import PackageDescription
import Foundation
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let dependencies: [Package.Dependency] = [
    .package(path: "Vendor/PhononCoreML"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
]
let appDependencies: [Target.Dependency] = ["UIUICore", "CMiniLM", .product(name: "PhononCoreML", package: "PhononCoreML"), .product(name: "FluidAudio", package: "FluidAudio")]
let package = Package(
    name: "uiui",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "uiui", targets: ["UIUI"]), .library(name: "UIUICore", targets: ["UIUICore"])],
    dependencies: dependencies,
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CMiniLM", path: "Sources/CMiniLM", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-std=c++17", "-I" + packageRoot + "/Vendor/MiniLM/include"])],
                linkerSettings: [.unsafeFlags([packageRoot + "/Vendor/MiniLM/lib/libsentencepiece.a",
                                               "-L" + packageRoot + "/Vendor/MiniLM/lib", "-lonnxruntime.1.23.2"]),
                                 .linkedLibrary("c++")]),
        .target(name: "UIUICore", dependencies: ["CSQLite"]),
        .executableTarget(name: "UIUI", dependencies: appDependencies,
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                                        "-Xlinker", "-rpath", "-Xlinker", packageRoot + "/Vendor/MiniLM/lib"])]),
        .testTarget(name: "UIUICoreTests", dependencies: ["UIUICore"]),
        .testTarget(name: "UIUIAppTests", dependencies: ["UIUI", "UIUICore"])
    ],
    swiftLanguageModes: [.v5]
)
