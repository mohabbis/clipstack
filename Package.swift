// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipstack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Clipstack", targets: ["Clipstack"]),
        .library(name: "ClipstackCore", targets: ["ClipstackCore"]),
    ],
    targets: [
        // Platform-independent logic: capture policy, storage, retention, search, settings.
        // Depends only on Foundation so it can be unit tested anywhere.
        .target(name: "ClipstackCore"),

        // The macOS menu-bar app (AppKit + SwiftUI). Every source file is wrapped in
        // `#if os(macOS)` so the package still builds (as a stub) on other platforms.
        .executableTarget(
            name: "Clipstack",
            dependencies: ["ClipstackCore"]
        ),

        .testTarget(
            name: "ClipstackCoreTests",
            dependencies: ["ClipstackCore"]
        ),
    ]
)
