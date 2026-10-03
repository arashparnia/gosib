// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gosib",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GosibCore", targets: ["GosibCore"]),
        .library(name: "GosibApple", targets: ["GosibApple"]),
        .executable(name: "gosib-demo", targets: ["GosibDemo"])
    ],
    targets: [
        .target(name: "GosibCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "GosibApple", dependencies: ["GosibCore"]),
        .executableTarget(name: "GosibDemo", dependencies: ["GosibCore", "GosibApple"]),
        .testTarget(name: "GosibCoreTests", dependencies: ["GosibCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "GosibAppleTests", dependencies: ["GosibApple", "GosibCore"])
    ],
    swiftLanguageVersions: [.v5]
)
