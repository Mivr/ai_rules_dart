// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_graph_plugin",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "spm_graph_plugin", targets: ["spm_graph_plugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-algorithms.git", exact: "1.2.0"),
        .package(url: "https://github.com/apple/swift-numerics.git", exact: "1.0.2")
    ],
    targets: [
        .target(
            name: "spm_graph_plugin",
            dependencies: [
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "RealModule", package: "swift-numerics"),
            ]
        )
    ]
)
