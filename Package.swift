// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SubtitleStudioPlus",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SubtitleStudioPlus", targets: ["SubtitleStudioPlus"]),
    ],
    targets: [
        .executableTarget(
            name: "SubtitleStudioPlus",
            path: "Sources"
        ),
        .testTarget(
            name: "SubtitleStudioPlusTests",
            dependencies: ["SubtitleStudioPlus"],
            path: "Tests"
        ),
    ]
)
