// swift-tools-version: 5.9

import PackageDescription
import Foundation

let almRecorderExcludes = [
    "Info.plist",
    "AlmRecorder.entitlements",
    "Resources/AppIcon.icns"
] + (FileManager.default.fileExists(atPath: "AlmRecorder/Tests") ? ["Tests"] : [])

let package = Package(
    name: "AlmRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AlmRecorder",
            targets: ["AlmRecorder"]
        ),
        .executable(
            name: "AlmRecorderMCPBridge",
            targets: ["AlmRecorderMCPBridge"]
        ),
        .library(
            name: "AlmRecorderMCPProtocol",
            targets: ["AlmRecorderMCPProtocol"]
        ),
        .library(
            name: "AlmRecorderEvaluationKit",
            targets: ["AlmRecorderEvaluationKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(url: "https://github.com/mattt/DBSCAN.git", from: "0.0.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(path: "GRDBCustom")
    ],
    targets: [
        .target(
            name: "AlmRecorderMCPProtocol",
            path: "Sources/AlmRecorderMCPProtocol"
        ),
        .target(
            name: "AlmRecorderEvaluationKit",
            path: "Sources/AlmRecorderEvaluationKit"
        ),
        .executableTarget(
            name: "AlmRecorderMCPBridge",
            dependencies: [
                "AlmRecorderMCPProtocol",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/AlmRecorderMCPBridge"
        ),
        .executableTarget(
            name: "AlmRecorder",
            dependencies: [
                "AlmRecorderMCPProtocol",
                "AlmRecorderEvaluationKit",
                .product(name: "GRDB", package: "GRDBCustom"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "DBSCAN", package: "DBSCAN")
            ],
            path: "AlmRecorder",
            exclude: almRecorderExcludes,
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/Libraries"),
                .copy("Resources/Binaries"),
                .copy("Resources/Models"),
                .copy("Resources/Python")
            ]
        )
    ]
)
