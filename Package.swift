// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "streetw",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // Everything that watches the web for changes. Shared verbatim between the
        // iOS app and the server (see BACKEND.md) — which is why nothing in here may
        // import SwiftData, SwiftUI or UIKit.
        .library(name: "StreetwCore", targets: ["StreetwCore"])
    ],
    dependencies: [
        // Re-exports CryptoKit on Apple platforms and provides it on Linux, so the
        // page fingerprinter compiles in the server's Docker image.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "StreetwCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "StreetwCoreTests",
            dependencies: ["StreetwCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
