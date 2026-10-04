// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WochenleichtCore",
    defaultLocalization: "de",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WochenleichtCore", targets: ["WochenleichtCore"]),
    ],
    targets: [
        .target(
            name: "WochenleichtCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "WochenleichtCoreTests",
            dependencies: ["WochenleichtCore"]
        ),
    ]
)
