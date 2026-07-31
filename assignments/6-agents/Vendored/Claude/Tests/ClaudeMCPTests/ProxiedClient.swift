import Foundation
import System
import ClaudeDomain
import MCP

@testable import ClaudeMCP

// MCP client wired through a real ToolProxy: client stdio lives on pipes, the proxy
// pumps them to the host's TCP port — the same byte path claude uses in production.
final class ProxiedClient: @unchecked Sendable {

	let client: Client

	private let clientToProxy = Pipe()
	private let proxyToClient = Pipe()
	private let proxy: Task<Void, any Error>

	init(port: UInt16) async throws {
		let input = clientToProxy.fileHandleForReading
		let output = proxyToClient.fileHandleForWriting
		proxy = Task {
			try await Claude.ToolProxy.run(port: port, input: input, output: output)
		}

		// The proxy releases its end of clientToProxy when it exits; a client write that races that
		// exit must fail with EPIPE, since a SIGPIPE here would take the whole test runner down.
		clientToProxy.fileHandleForWriting.suppressBrokenPipeSignal()

		client = Client(name: "ClaudeMCPTests", version: "1.0.0")
		let transport = StdioTransport(
			input: FileDescriptor(rawValue: proxyToClient.fileHandleForReading.fileDescriptor),
			output: FileDescriptor(rawValue: clientToProxy.fileHandleForWriting.fileDescriptor))
		_ = try await client.connect(transport: transport)
	}

	func shutdown() async {
		await client.disconnect()
		try? clientToProxy.fileHandleForWriting.close()
		proxy.cancel()
	}

}
