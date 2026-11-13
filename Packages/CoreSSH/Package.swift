// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreSSH",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
    ],
    targets: [
        .target(name: "CoreModels"),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
    ]
)
