import Foundation

// The subcommand names the binary answers to. `mcp-proxy` is not a user-facing command: claude spawns
// this same executable with it as the MCP server for the session's hosted tools, and the transport is
// configured with the very same string — so both halves read it from here rather than from two literals
// that can drift apart.
public enum CLICommand: Sendable {

	public static let proxy = "mcp-proxy"
	public static let smoke = "smoke"
}
