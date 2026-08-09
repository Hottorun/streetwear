// swift-tools-version: 6.0
import PackageDescription

// Deliberately a *separate* package from the root one. If Vapor and Fluent were
// dependencies of the root package, opening the iOS app in Xcode would resolve and
// build the entire server dependency tree. StreetwCore comes in by path, so the
// adapters are shared source, not a copy.
let package = Package(
    name: "StreetwServer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.106.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0")
    ],
    targets: [
        .executableTarget(
            name: "StreetwServer",
            dependencies: [
                .product(name: "StreetwCore", package: "streetw"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ]
        ),
        .testTarget(
            name: "StreetwServerTests",
            dependencies: [
                .target(name: "StreetwServer"),
                .product(name: "VaporTesting", package: "vapor")
            ]
        )
    ]
)
