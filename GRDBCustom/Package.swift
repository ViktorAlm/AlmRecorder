// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GRDBCustom",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GRDB",
            targets: ["GRDB"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "GRDB",
            path: "Binary/GRDB.xcframework"
        )
    ]
)