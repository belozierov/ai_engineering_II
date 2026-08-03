// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ops-copilot",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.10.1"),
        .package(url: "https://github.com/mattt/JSONSchema", from: "1.3.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "ClaudeKit",
            dependencies: [
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .target(name: "OpsCore"),
        .target(
            name: "OpsSourceTools",
            dependencies: [
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        ),
        .target(name: "OpsFactMemory", dependencies: ["OpsCore", "OpsEvidenceGuard", "ClaudeKit"]),
        .target(
            name: "OpsProcedures",
            dependencies: [
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        ),
        .target(name: "OpsCompaction", dependencies: ["OpsCore", "ClaudeKit"]),
        .target(name: "OpsEvidenceGuard", dependencies: ["OpsCore"]),
        .target(
            name: "OpsAgent",
            dependencies: [
                "OpsCore",
                "OpsSourceTools",
                "OpsFactMemory",
                "OpsProcedures",
                "OpsCompaction",
                "OpsEvidenceGuard",
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        ),
        .target(
            name: "OpsCLI",
            dependencies: [
                "OpsAgent",
                "OpsCore",
                "OpsSourceTools",
                "OpsFactMemory",
                "OpsProcedures",
                "ClaudeKit"
            ]
        ),
        .target(
            name: "OpsEval",
            dependencies: [
                "OpsCLI",
                "OpsAgent",
                "OpsCore",
                "OpsSourceTools",
                "OpsFactMemory",
                "OpsProcedures",
                "OpsCompaction",
                "OpsEvidenceGuard",
                "ClaudeKit"
            ]
        ),
        .executableTarget(
            name: "ops-cli",
            dependencies: [
                "OpsCLI",
                "OpsAgent",
                "OpsCore",
                "OpsSourceTools",
                "ClaudeKit"
            ]
        ),
        .executableTarget(name: "ops-eval", dependencies: ["OpsEval"]),
        .testTarget(
            name: "ClaudeKitTests",
            dependencies: [
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(name: "OpsCoreTests", dependencies: ["OpsCore"]),
        .testTarget(
            name: "OpsEvalTests",
            dependencies: [
                "OpsEval",
                "OpsCLI",
                "OpsAgent",
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeKit"
            ]
        ),
        .testTarget(
            name: "OpsAgentTests",
            dependencies: [
                "OpsAgent",
                "OpsCore",
                "OpsCompaction",
                "OpsEvidenceGuard",
                "OpsSourceTools",
                "OpsFactMemory",
                "OpsProcedures",
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "OpsCLITests",
            dependencies: [
                "OpsCLI",
                "OpsAgent",
                "OpsCore",
                "OpsEvidenceGuard",
                "OpsSourceTools",
                "ClaudeKit"
            ]
        ),
        .testTarget(name: "OpsEvidenceGuardTests", dependencies: ["OpsEvidenceGuard", "OpsCore"]),
        .testTarget(
            name: "OpsCompactionTests",
            dependencies: ["OpsCompaction", "OpsCore", "ClaudeKit"]
        ),
        .testTarget(
            name: "OpsSourceToolsTests",
            dependencies: [
                "OpsSourceTools",
                "OpsCore",
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "OpsFactMemoryTests",
            dependencies: ["OpsFactMemory", "OpsEvidenceGuard", "OpsCore", "ClaudeKit"]),
        .testTarget(
            name: "OpsProceduresTests",
            dependencies: [
                "OpsProcedures",
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeKit",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
