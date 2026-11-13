// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreSSH",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
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
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore", "CoreModels", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ]
)
