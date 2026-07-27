import ArgumentParser
import ClaudeRuntime

// Hidden service subcommand. Claude spawns THIS binary with the `mcp-proxy` argument (see
// Claude.ToolProxyCommand.subcommand), and the proxy tunnels stdio ↔ the parent process's
// loopback ToolHost. It must do nothing but bridge bytes — no index, no MLX, no encoder —
// so the spawned instance stays cheap. See the HW5 handoff doc, "Потік одного запиту".
extension RAG {

    struct MCPProxy: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "mcp-proxy",
            abstract: "Internal: stdio↔TCP bridge spawned by claude to reach the in-process tool host.",
            shouldDisplay: false
        )

        func run() async throws {
            try await Claude.ToolProxy.run()
        }
    }
}
