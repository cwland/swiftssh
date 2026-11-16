// swift-tools-version: 6.0
import PackageDescription

/// SwiftSSH's shared look: the colour and size tokens, card and badge views and terminal-theme
/// colour helpers, used by both the Mac app (App/) and the iPhone/iPad app (App-iOS/) so the two
/// can't drift apart. SwiftUI only: it builds on macOS and iOS, not on Linux.
let package = Package(
    name: "SwiftSSHUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SwiftSSHUI", targets: ["SwiftSSHUI"]),
    ],
    dependencies: [
        .package(path: "../CoreSSH"),
    ],
    targets: [
        .target(
            name: "SwiftSSHUI",
            dependencies: [
                .product(name: "AppCore", package: "CoreSSH"),
                .product(name: "CoreModels", package: "CoreSSH"),
            ]
        ),
    ]
)
