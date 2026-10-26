// swift-tools-version: 6.1
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
    swiftLanguageModes: [.v5]
)
