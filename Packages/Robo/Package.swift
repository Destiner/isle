// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Robo",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Robo", targets: ["Robo"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "Robo",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RoboTests",
            dependencies: ["Robo"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
