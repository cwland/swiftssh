// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreSSH",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "SyncTestSupport", targets: ["SyncTestSupport"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "SSHCore", targets: ["SSHCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMinor(from: "0.12.1")),
    ],
    targets: [
        .target(name: "CoreModels"),
        .target(
            name: "SyncCore",
            dependencies: [
                "CoreModels",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "SSHCore",
            dependencies: [
                "CoreModels",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "AppCore",
            dependencies: [
                "CoreModels",
                "SyncCore",
                "SSHCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(name: "SyncTestSupport", dependencies: ["SyncCore", "CoreModels"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "CoreModels", "SyncCore"]),
        .testTarget(name: "SSHCoreTests", dependencies: ["SSHCore", "CoreModels"]),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore", "CoreModels", "SyncTestSupport", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ]
)
