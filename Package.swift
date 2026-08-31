// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DupFinder",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DupFinderCore", targets: ["DupFinderCore"]),
        .executable(name: "DupFinder", targets: ["DupFinderApp"]),
    ],
    targets: [
        .target(name: "DupFinderCore"),
        .executableTarget(name: "DupFinderApp", dependencies: ["DupFinderCore"]),
    ]
)
