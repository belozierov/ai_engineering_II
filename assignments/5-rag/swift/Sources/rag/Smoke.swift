import ArgumentParser
import ClaudeRuntime
import Foundation
import JSONSchema
import Logging

// De-risking probe for the hosted-tool chain (HW5 handoff, Risks → "mcp-proxy × MLX dyld"):
// our MLX-linked binary → claude -p → claude spawns this same binary as `mcp-proxy` → the proxy
// dials back to the in-process ToolHost. A trivial tool with a forced call proves every hop
// without loading the index or the encoder.
extension RAG {

    struct Smoke: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "smoke",
            abstract: "Internal: minimal end-to-end probe of the hosted-tool (MCP proxy) chain.",
            shouldDisplay: false
        )

        func run() async throws {
            if ProcessInfo.processInfo.environment["RAG_LOG"] != nil {
                LoggingSystem.bootstrap { label in
                    var handler = StreamLogHandler.standardError(label: label)
                    handler.logLevel = .trace
                    return handler
                }
            }

            let factory = try CLISessionFactory(
                workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath),
                toolProxy: .subcommand("mcp-proxy")
            )

            let configuration = Claude.SessionConfiguration(
                model: .haiku,
                systemPrompt: "You are a test harness. Do exactly what the user asks using the provided tool.",
                tools: [],
                maxTurns: 3,
                hostedTools: [PingTool()],
                features: AgentFeatures.clean,
                requestTimeout: .seconds(120)
            )

            let session = factory.create(configuration, origin: .new)
            let result = try await session.send("Call the `ping` tool with message \"hello\" and reply with exactly the text it returns, nothing else.")

            print("=== smoke answer ===")
            print(result.output)
            print("=== usage: cost=$\(result.usage.costUSD ?? 0), in=\(result.usage.inputTokens), out=\(result.usage.outputTokens) ===")
        }
    }
}

private struct PingTool: Claude.HostedTool {

    struct Arguments: Claude.SchemaRepresentable, Decodable {

        static let schema: JSONSchema = .object(
            properties: ["message": .string(description: "Message to echo back")],
            required: ["message"])

        let message: String
    }

    let name = "ping"
    let description = "Echoes the given message back, prefixed with 'pong:'."

    func call(_ arguments: Arguments) async throws -> String {
        FileHandle.standardError.write(Data("  | PING     message=\(arguments.message)\n".utf8))
        return "pong: \(arguments.message)"
    }
}
