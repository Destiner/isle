// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Roboport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Roboport", targets: ["Roboport"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "Roboport",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RoboportTests",
            dependencies: ["Roboport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
