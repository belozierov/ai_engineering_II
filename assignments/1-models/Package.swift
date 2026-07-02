// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hw1",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Pin to a release tag: on `main` the LLM libraries are NOT exposed as SwiftPM products.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", .upToNextMinor(from: "2.29.1")),
        // Direct dependency only for MLX.seed (matches the version mlx-swift-examples pins).
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.29.1"))
    ],
    targets: [
        .target(
            name: "HW1Core",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXVLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "MLX", package: "mlx-swift")
            ]
        ),
        .executableTarget(name: "hw1", dependencies: ["HW1Core"]),
        .executableTarget(name: "ladder", dependencies: ["HW1Core"])
    ]
)
