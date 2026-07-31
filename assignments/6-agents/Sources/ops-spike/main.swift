import Foundation
import ClaudeDomain
import ClaudeMCP

// One binary, two roles: claude spawns this same executable as the MCP server for the session's
// hosted tools, and the proxy pumps that stdio onto the loopback port the in-process host listens
// on. Nothing but MCP traffic may reach stdout on that path — every diagnostic printed by the
// spike belongs to the other role only.
if CommandLine.arguments.dropFirst().first == Spike.proxySubcommand {
	try await Claude.ToolProxy.run()
} else {
	let report = try await Spike().run()
	print(report.rendered)
	exit(report.isPassing ? 0 : 1)
}
