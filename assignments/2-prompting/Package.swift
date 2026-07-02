// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "roster",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "roster")
    ]
)
