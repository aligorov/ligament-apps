// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "link-worker-darwin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "link-worker-darwin", targets: ["LinkWorker"])
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip",
            checksum: "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
        ),
        .executableTarget(
            name: "LinkWorker",
            dependencies: [
                "WebRTC"
            ],
            path: "Sources/LinkWorker",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/PackageFrameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Applications/Ligament 2FA.app/Contents/Frameworks"
                ]),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "LinkWorkerTests",
            dependencies: ["LinkWorker"],
            path: "Tests/LinkWorkerTests"
        )
    ]
)
