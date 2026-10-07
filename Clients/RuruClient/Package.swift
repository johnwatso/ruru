// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RuruClient",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "RuruClient", targets: ["RuruClient"])],
    targets: [
        .target(name: "RuruClient"),
        .testTarget(name: "RuruClientTests", dependencies: ["RuruClient"])
    ]
)
