import Foundation

extension Claude {

	public struct ToolProxyCommand: Sendable {

		// The mcp-config key claude prefixes tool names with: mcp__<serverName>__<tool>.
		public static let serverName = "app"
		public static let portEnvironmentVariable = "CLAUDE_MCP_PORT"

		public let executable: URL
		public let arguments: [String]

		public init(executable: URL, arguments: [String] = []) {
			self.executable = executable
			self.arguments = arguments
		}

		public static func subcommand(_ name: String) -> ToolProxyCommand {
			let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
			return ToolProxyCommand(executable: executable, arguments: [name])
		}

	}

}
