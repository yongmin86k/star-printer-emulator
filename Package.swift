// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StarEmu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StarEmuCore", targets: ["StarEmuCore"]),
        .executable(name: "staremu", targets: ["staremu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "StarEmuCore"),
        .executableTarget(
            name: "staremu",
            dependencies: [
                "StarEmuCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "StarEmuCoreTests",
            dependencies: ["StarEmuCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
