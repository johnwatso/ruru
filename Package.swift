// swift-tools-version:5.10
import PackageDescription

/// The public SwiftPM surface of the Ruru repository.
///
/// Ruru itself remains a native Xcode app. Only `RuruClient` is exposed as a
/// package product, so integrating apps do not link the authority, UI, or
/// bundled tools.
let package = Package(
    name: "Ruru",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RuruClient", targets: ["RuruClient"])
    ],
    targets: [
        .target(name: "RuruClient", path: "Clients/RuruClient/Sources/RuruClient"),
        .testTarget(
            name: "RuruClientTests",
            dependencies: ["RuruClient"],
            path: "Clients/RuruClient/Tests/RuruClientTests"
        )
    ]
)
