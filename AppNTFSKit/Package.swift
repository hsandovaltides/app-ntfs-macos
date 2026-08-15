// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppNTFSKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AppNTFSKit",
            targets: ["AppNTFSKit"]
        )
    ],
    targets: [
        .target(
            name: "AppNTFSKit"
        ),
        .testTarget(
            name: "AppNTFSKitTests",
            dependencies: ["AppNTFSKit"]
        )
    ]
)
