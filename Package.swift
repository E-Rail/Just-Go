// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JustGo",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "JustGo",
            targets: ["JustGo"]
        )
    ],
    dependencies: [
        // AMap SDK will be added via SPM or CocoaPods when API key is obtained
    ],
    targets: [
        .target(
            name: "JustGo",
            dependencies: [],
            path: "JustGo"
        ),
        .testTarget(
            name: "JustGoTests",
            dependencies: ["JustGo"],
            path: "JustGoTests"
        )
    ]
)
