// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "link-worker-ios",
    platforms: [
        .iOS(.v14),
        .macOS(.v13)
    ],
    products: [
        .library(name: "LinkWorkerIOS", targets: ["LinkWorkerIOS"])
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip",
            checksum: "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
        ),
        .target(
            name: "LinkWorkerIOS",
            dependencies: [
                "WebRTC"
            ],
            path: "Sources/LinkWorkerIOS",
            linkerSettings: [
                .linkedFramework("ReplayKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "LinkWorkerIOSTests",
            dependencies: ["LinkWorkerIOS"],
            path: "Tests/LinkWorkerIOSTests"
        )
    ]
)
