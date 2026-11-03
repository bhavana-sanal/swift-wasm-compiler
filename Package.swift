// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-wasm-compiler",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ternc", targets: ["ternc"]),
        .library(name: "TernCore", targets: ["TernCore"]),
    ],
    targets: [
        .target(
            name: "TernCore",
            resources: [.copy("Resources/run.mjs")]
        ),
        .executableTarget(
            name: "ternc",
            dependencies: ["TernCore"]
        ),
        .testTarget(
            name: "TernCoreTests",
            dependencies: ["TernCore"]
        ),
    ]
)
