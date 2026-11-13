// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Run", targets: ["Run"]),
        .library(name: "SyncServer", targets: ["SyncServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(path: "../Packages/CoreSSH"),
    ],
    targets: [
        .target(
            name: "SyncServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "CoreModels", package: "CoreSSH"),
                .product(name: "SyncCore", package: "CoreSSH"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Run",
            dependencies: ["SyncServer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SyncServerTests",
            dependencies: [
                "SyncServer",
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "CoreModels", package: "CoreSSH"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
