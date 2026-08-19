// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DisplayTransformer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "DisplayTransformer",
            targets: ["DisplayTransformer"]
        )
    ],
    targets: [
        .target(
            name: "TransformerCore"
        ),
        .executableTarget(
            name: "DisplayTransformer",
            dependencies: ["TransformerCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "TransformerCoreTests",
            dependencies: ["TransformerCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
