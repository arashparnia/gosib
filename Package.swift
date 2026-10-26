// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PechPech",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PechPechCore", targets: ["PechPechCore"]),
        .library(name: "PechPechApple", targets: ["PechPechApple"]),
        .executable(name: "pechpech-demo", targets: ["PechPechDemo"])
    ],
    targets: [
        .target(name: "PechPechCore", resources: [.process("Resources")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "PechPechApple", dependencies: ["PechPechCore"],
                resources: [.process("Resources")]),
        .executableTarget(name: "PechPechDemo", dependencies: ["PechPechCore", "PechPechApple"]),
        .testTarget(name: "PechPechCoreTests", dependencies: ["PechPechCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PechPechAppleTests", dependencies: ["PechPechApple", "PechPechCore"])
    ],
    swiftLanguageModes: [.v5]
)
