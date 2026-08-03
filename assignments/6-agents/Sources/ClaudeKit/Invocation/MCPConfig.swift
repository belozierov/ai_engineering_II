import Foundation

extension Invocation {

	struct MCPConfig: Sendable {

		enum Errors: Error, Equatable {
			case duplicateServerName(String)
		}

		struct Server: Sendable {

			var name: String
			var executable: URL
			var arguments: [String]
			var environment: [String: String]

			init(name: String, executable: URL, arguments: [String] = [], environment: [String: String] = [:]) {
				self.name = name
				self.executable = executable
				self.arguments = arguments
				self.environment = environment
			}

		}

		var servers: [Server]

		init(servers: [Server]) {
			self.servers = servers
		}

		func makeJSON() throws -> String {
			var mcpServers: [String: Payload.Server] = [:]
			mcpServers.reserveCapacity(servers.count)

			for server in servers {
				guard mcpServers[server.name] == nil else { throw Errors.duplicateServerName(server.name) }
				mcpServers[server.name] = Payload.Server(
					command: server.executable.path(percentEncoded: false),
					args: server.arguments,
					env: server.environment)
			}

			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
			let data = try encoder.encode(Payload(mcpServers: mcpServers))
			return String(decoding: data, as: UTF8.self)
		}

	}

}

// MARK: Proxy Convenience

extension Invocation.MCPConfig {

	// The TCP-proxy topology is one stdio server named after the proxy, carrying the port in its environment.
	init(proxy: Claude.ToolProxyCommand, port: UInt16) {
		self.init(servers: [
			Server(
				name: Claude.ToolProxyCommand.serverName,
				executable: proxy.executable,
				arguments: proxy.arguments,
				environment: [Claude.ToolProxyCommand.portEnvironmentVariable: String(port)])
		])
	}

}

// MARK: Encoding

private extension Invocation.MCPConfig {

	struct Payload: Encodable {

		let mcpServers: [String: Server]

		struct Server: Encodable {
			let command: String
			let args: [String]
			let env: [String: String]
		}

	}

}
