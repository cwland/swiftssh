// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreSSH",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "SyncTestSupport", targets: ["SyncTestSupport"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
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
            name: "AppCore",
            dependencies: [
                "CoreModels",
                "SyncCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(name: "SyncTestSupport", dependencies: ["SyncCore", "CoreModels"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "CoreModels", "SyncCore"]),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore", "CoreModels", "SyncTestSupport", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ]
)
