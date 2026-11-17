// swift-tools-version:5.9
// The shared Rust core (crates/core) for the iOS app, through UniFFI (crates/ffi).
// Build the binary first: scripts/build-ios-core.sh [--sim] (docs/streams/ios-core.md).
import PackageDescription

let package = Package(
    name: "EncoreCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "EncoreCore", targets: ["EncoreCore"]),
    ],
    dependencies: [
        // libmpv + FFmpeg for crates/player (plan §2.2). Same pin as the S1 audio spike.
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .binaryTarget(name: "EncoreCoreFFI", path: "build/EncoreCoreFFI.xcframework"),
        .target(
            name: "EncoreCore",
            dependencies: [
                "EncoreCoreFFI",
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(name: "EncoreCoreTests", dependencies: ["EncoreCore"]),
    ]
)
