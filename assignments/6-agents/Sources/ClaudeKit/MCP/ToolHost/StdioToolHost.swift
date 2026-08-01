import Foundation
import Logging
import MCP

// A standalone MCP server over the current process's stdin/stdout — the shape Claude Code
// spawns from an `mcpServers` config entry. Unlike ToolHost's loopback-TCP topology (a
// listener per CLI-driver session), this serves a single client that has fully initialized
// the server before its first use, so there is no registration-confirmation gate to run.
struct StdioToolHost: Sendable {

	typealias Errors = HostedToolSet.Errors

	private let name: String
	private let version: String
	private let toolSet: HostedToolSet
	private let logger = Logger(label: "ClaudeKit.StdioToolHost")

	// Same preflight as ToolHost: duplicate names, non-object schemas, and $ref are rejected up front.
	init(name: String, version: String, tools: [any Claude.HostedTool]) throws {
		self.name = name
		self.version = version
		self.toolSet = try HostedToolSet(tools: tools)
	}

	// MARK: Serving

	// Internal seam: tests drive the same path through the SDK's in-memory transport pair.
	func run(transport: some Transport) async throws {
		let server = Server(name: name, version: version, capabilities: Server.Capabilities(tools: .init()))

		await server.withMethodHandler(ListTools.self) { [toolSet, logger] _ in
			logger.debug("ListTools: \(toolSet.declarations.map(\.name).joined(separator: ", "))")
			return ListTools.Result(tools: toolSet.declarations)
		}

		await server.withMethodHandler(CallTool.self) { [toolSet, logger] parameters in
			await toolSet.callResult(for: parameters, logger: logger)
		}

		logger.debug("Serving \(toolSet.declarations.count) tools over stdio")
		try await server.start(transport: transport)
		await server.waitUntilCompleted()
	}

}
