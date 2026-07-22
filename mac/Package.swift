// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "netdisplay-sender",
    platforms: [.macOS(.v14)],
    targets: [
        // C target that exposes the private CGVirtualDisplay Objective-C headers
        // to Swift. The classes themselves are provided at runtime by CoreGraphics
        // (SkyLight); this target only carries their interface declarations.
        .target(
            name: "CVirtualDisplay"
        ),
        .executableTarget(
            name: "netdisplay-sender",
            dependencies: ["CVirtualDisplay"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
    ]
)
