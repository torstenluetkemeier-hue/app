// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AnrufbeantworterCore",
    defaultLocalization: "de",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnrufbeantworterCore", targets: ["AnrufbeantworterCore"]),
    ],
    targets: [
        .target(name: "AnrufbeantworterCore"),
        .testTarget(name: "AnrufbeantworterCoreTests", dependencies: ["AnrufbeantworterCore"]),
    ]
)
