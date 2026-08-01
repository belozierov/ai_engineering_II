import Foundation
import ClaudeKit
import OpsCLI

// One binary, three roles: claude spawns this same executable as the MCP server for the session's hosted
// tools, and the proxy pumps that stdio onto the loopback port the in-process host listens on — nothing but
// MCP traffic may reach stdout on that path. The dev-only smoke keeps its own composition, and everything
// else is the operator console, which owns its flags, its exit codes and both output modes.
switch CommandLine.arguments.dropFirst().first {
case CLICommand.proxy:
	try await Claude.ToolProxy.run()

case CLICommand.smoke:
	do {
		exit(try await Smoke().run() ? 0 : 1)
	} catch {
		FileHandle.standardError.write(Data("ops-cli: smoke failed — \(error)\n".utf8))
		exit(1)
	}

default:
	exit(await OperatorConsole().run(arguments: Array(CommandLine.arguments.dropFirst())).rawValue)
}
