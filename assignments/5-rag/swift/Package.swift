// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "rag",
    platforms: [.macOS(.v26)],
    dependencies: [
        // MLX stack copied faithfully from hw4 4-embeddings (exact versions) — RAGEmbedding is
        // the only MLX-linked target. See the HW5 handoff doc, DECISION 4 (copy, not path dep).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // Runtime stack for driving `claude -p` with hosted MCP tools — versions mirror the private
        // Claude package the ClaudeRuntime slice is copied from. See the HW5 handoff doc, DECISION 3.
        .package(url: "https://github.com/apple/swift-log", from: "1.10.1"),
        .package(url: "https://github.com/mattt/JSONSchema", from: "1.3.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0")
    ],
    targets: [
        .target(name: "RAGCore"),
        .target(name: "RAGIndexing", dependencies: ["RAGCore"]),
        .target(name: "RAGRetrieval", dependencies: ["RAGCore"]),
        .target(name: "RAGPacking", dependencies: ["RAGCore"]),
        .target(name: "RAGValidation", dependencies: ["RAGCore"]),
        .target(name: "RAGSecurity", dependencies: ["RAGCore"]),
        .target(name: "RAGQueryTransform", dependencies: ["RAGCore"]),
        .target(name: "RAGIndexStore", dependencies: ["RAGCore"]),
        .target(name: "RAGEval", dependencies: ["RAGCore"]),
        // FoundationModels-backed article descriptions for the "fm" contextual-retrieval strategy.
        // System-framework only (no MLX) — builds under plain `swift build`; linked into `rag` only.
        .target(name: "RAGContextualizer", dependencies: ["RAGCore"]),
        // Copied slice of the private Claude package (spawn + MCP tool hosting). Deliberately MLX-free
        // so it links into the mcp-proxy subcommand without the Metal runtime. See handoff DECISION 3.
        .target(
            name: "ClaudeRuntime",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .target(
            name: "RAGEmbedding",
            dependencies: [
                "RAGCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .executableTarget(
            name: "rag",
            dependencies: [
                "RAGCore", "RAGIndexing", "RAGRetrieval", "RAGPacking", "RAGValidation",
                "RAGSecurity", "RAGQueryTransform", "RAGIndexStore", "RAGEval", "RAGEmbedding",
                "RAGContextualizer", "ClaudeRuntime",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "RAGIndexingTests", dependencies: ["RAGIndexing", "RAGCore"]),
        .testTarget(name: "RAGRetrievalTests", dependencies: ["RAGRetrieval", "RAGCore"]),
        .testTarget(name: "RAGPackingTests", dependencies: ["RAGPacking", "RAGCore"]),
        .testTarget(name: "RAGValidationTests", dependencies: ["RAGValidation", "RAGCore"]),
        .testTarget(name: "RAGIndexStoreTests", dependencies: ["RAGIndexStore", "RAGCore"]),
        .testTarget(name: "RAGEvalTests", dependencies: ["RAGEval", "RAGCore"]),
        .testTarget(name: "RAGQueryTransformTests", dependencies: ["RAGQueryTransform", "RAGCore"]),
        .testTarget(name: "RAGSecurityTests", dependencies: ["RAGSecurity", "RAGCore"])
    ],
    swiftLanguageModes: [.v6]
)
