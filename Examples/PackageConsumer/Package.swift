// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PechPechPackageConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "PackageConsumer", dependencies: [
            .product(name: "PechPechCore", package: "pechpech"),
            .product(name: "PechPechApple", package: "pechpech")
        ])
    ],
    swiftLanguageVersions: [.v5]
)
