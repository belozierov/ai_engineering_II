// swift-tools-version: 6.3
import PackageDescription

// Vendored subset of the Claude kit — see Vendored/Claude/README.md for provenance.
let vendoredSources = "Vendored/Claude/Sources"
let vendoredTests = "Vendored/Claude/Tests"

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
            name: "ClaudeDomain",
            dependencies: [.product(name: "JSONSchema", package: "JSONSchema")],
            path: "\(vendoredSources)/ClaudeDomain"
        ),
        .target(
            name: "ClaudeInvocation",
            dependencies: ["ClaudeDomain"],
            path: "\(vendoredSources)/ClaudeInvocation"
        ),
        .target(
            name: "ClaudeMCP",
            dependencies: [
                "ClaudeDomain",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "\(vendoredSources)/ClaudeMCP"
        ),
        .target(
            name: "ClaudeCLI",
            dependencies: [
                "ClaudeDomain",
                "ClaudeInvocation",
                "ClaudeMCP",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "\(vendoredSources)/ClaudeCLI"
        ),
        .target(name: "ClaudeTranscript", path: "\(vendoredSources)/ClaudeTranscript"),
        .target(
            name: "ClaudeSessions",
            dependencies: ["ClaudeTranscript"],
            path: "\(vendoredSources)/ClaudeSessions"
        ),
        .target(name: "OpsCore"),
        .target(
            name: "OpsSourceTools",
            dependencies: [
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeDomain",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        ),
        .target(name: "OpsFactMemory", dependencies: ["OpsCore", "OpsEvidenceGuard", "ClaudeDomain"]),
        .target(
            name: "OpsProcedures",
            dependencies: [
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeDomain",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        ),
        .target(name: "OpsCompaction", dependencies: ["OpsCore", "ClaudeTranscript"]),
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
                "ClaudeDomain",
                "ClaudeMCP",
                "ClaudeCLI",
                "ClaudeTranscript",
                "ClaudeSessions",
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
                "ClaudeDomain"
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
                "ClaudeDomain",
                "ClaudeCLI"
            ]
        ),
        .executableTarget(
            name: "ops-cli",
            dependencies: [
                "OpsCLI",
                "OpsAgent",
                "OpsCore",
                "OpsSourceTools",
                "ClaudeDomain",
                "ClaudeMCP"
            ]
        ),
        .executableTarget(name: "ops-eval", dependencies: ["OpsEval"]),
        .executableTarget(
            name: "ops-spike",
            dependencies: [
                "ClaudeDomain",
                "ClaudeInvocation",
                "ClaudeMCP",
                "ClaudeCLI",
                "ClaudeSessions",
                "ClaudeTranscript",
                .product(name: "JSONSchema", package: "JSONSchema")
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
                "ClaudeDomain"
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
                "ClaudeDomain",
                "ClaudeMCP",
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
                "ClaudeDomain"
            ]
        ),
        .testTarget(name: "OpsEvidenceGuardTests", dependencies: ["OpsEvidenceGuard", "OpsCore"]),
        .testTarget(
            name: "OpsCompactionTests",
            dependencies: ["OpsCompaction", "OpsCore", "ClaudeTranscript"]
        ),
        .testTarget(
            name: "OpsSourceToolsTests",
            dependencies: [
                "OpsSourceTools",
                "OpsCore",
                "ClaudeDomain",
                "ClaudeMCP",
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(name: "OpsFactMemoryTests", dependencies: ["OpsFactMemory", "OpsEvidenceGuard", "OpsCore"]),
        .testTarget(
            name: "OpsProceduresTests",
            dependencies: [
                "OpsProcedures",
                "OpsCore",
                "OpsEvidenceGuard",
                "ClaudeDomain",
                .product(name: "JSONSchema", package: "JSONSchema")
            ]
        ),
        .testTarget(
            name: "ClaudeMCPTests",
            dependencies: [
                "ClaudeMCP",
                "ClaudeDomain",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "\(vendoredTests)/ClaudeMCPTests"
        ),
        .testTarget(
            name: "ClaudeInvocationTests",
            dependencies: [
                "ClaudeInvocation",
                "ClaudeDomain",
                .product(name: "JSONSchema", package: "JSONSchema")
            ],
            path: "\(vendoredTests)/ClaudeInvocationTests"
        ),
        .testTarget(
            name: "ClaudeTranscriptTests",
            dependencies: [
                "ClaudeTranscript",
                "ClaudeDomain",
                "ClaudeCLI"
            ],
            path: "\(vendoredTests)/ClaudeTranscriptTests"
        ),
        .testTarget(
            name: "ClaudeSessionsTests",
            dependencies: [
                "ClaudeSessions",
                "ClaudeTranscript"
            ],
            path: "\(vendoredTests)/ClaudeSessionsTests"
        ),
        .testTarget(
            name: "ClaudeCLITests",
            dependencies: [
                "ClaudeCLI",
                "ClaudeDomain",
                .product(name: "JSONSchema", package: "JSONSchema")
            ],
            path: "\(vendoredTests)/ClaudeCLITests"
        )
    ],
    swiftLanguageModes: [.v6]
)
