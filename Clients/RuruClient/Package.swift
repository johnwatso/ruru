// swift-tools-version:5.10
import PackageDescription

// This nested manifest is used only by Ruru's Xcode project. External clients
// resolve the repository-root Package.swift instead; keeping these manifests
// aligned avoids asking Xcode to resolve the project as its own package.
let package = Package(
    name: "RuruClient",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "RuruClient", targets: ["RuruClient"])],
    targets: [
        .target(name: "RuruClient"),
        .testTarget(name: "RuruClientTests", dependencies: ["RuruClient"])
    ]
)
