// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContainerStudio",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
    ],
    targets: [
        .target(name: "StudioCore"),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
    ]
)
