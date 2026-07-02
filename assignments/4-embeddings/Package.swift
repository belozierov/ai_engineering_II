// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ticket-search",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
        // Pinned to the last release without the NumKong dependency: NumKong's header-only
        // CNumKong target produces no object file, which breaks the xcodebuild link step we
        // need for MLX (ashvardanian/NumKong#353). Unpin once the fix lands upstream.
        .package(url: "https://github.com/unum-cloud/usearch", exact: "2.24.0")
    ],
    targets: [
        .target(name: "TicketSearchCore"),
        .target(
            name: "TextEmbedding",
            dependencies: [
                "TicketSearchCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .target(name: "Clustering", dependencies: ["TicketSearchCore"]),
        .target(name: "Naming", dependencies: ["TicketSearchCore"]),
        .target(name: "Retrieval", dependencies: ["TicketSearchCore"]),
        .target(
            name: "VectorStore",
            dependencies: ["TicketSearchCore", .product(name: "USearch", package: "usearch")]
        ),
        .target(name: "TicketHelper", dependencies: ["TicketSearchCore", "Clustering", "Retrieval"]),
        .target(name: "Visualization", dependencies: ["TicketSearchCore"]),
        .target(
            name: "Reranking",
            dependencies: [
                "TicketSearchCore",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "ticket-search",
            dependencies: [
                "TicketSearchCore", "TextEmbedding", "Clustering", "Naming",
                "Retrieval", "VectorStore", "TicketHelper", "Visualization", "Reranking"
            ]
        ),
        .testTarget(name: "TicketSearchCoreTests", dependencies: ["TicketSearchCore"]),
        .testTarget(
            name: "TextEmbeddingTests",
            dependencies: ["TextEmbedding", "TicketSearchCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ClusteringTests", dependencies: ["Clustering", "TicketSearchCore"]),
        .testTarget(name: "RetrievalTests", dependencies: ["Retrieval", "TicketSearchCore"]),
        .testTarget(name: "VectorStoreTests", dependencies: ["VectorStore", "Retrieval", "TicketSearchCore"]),
        .testTarget(name: "TicketHelperTests", dependencies: ["TicketHelper", "Clustering", "TicketSearchCore"]),
        .testTarget(name: "RerankingTests", dependencies: ["Reranking", "TicketSearchCore"])
    ],
    swiftLanguageModes: [.v6]
)
