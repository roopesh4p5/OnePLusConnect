// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OnePlusConnect",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C shim that talks to the private CGVirtualDisplay API family
        // through NSClassFromString so there is no link-time dependency.
        .target(
            name: "CGVirtualDisplayShim",
            path: "Sources/CGVirtualDisplayShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "OnePlusConnect",
            dependencies: ["CGVirtualDisplayShim"],
            path: "Sources/OnePlusConnect",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("IOKit"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
