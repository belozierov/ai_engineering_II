import Foundation
import Network
import ClaudeDomain
import Testing

@testable import ClaudeMCP

@Suite("ToolProxy teardown")
struct ToolProxyTests {

	// claude exits before the host on a normal turn, closing the reader of the proxy's output
	// while host bytes are still in flight — a `tools/list_changed` nudge, most often. That
	// write used to raise SIGPIPE and kill the process, which in a test run is the whole
	// runner: a rare "exited with unexpected signal code 13" with no failing test named.
	// The proxy must read the closed reader as EOF and wind down instead.
	@Test
	func closedOutputReaderEndsTheProxyCleanly() async throws {
		let queue = DispatchQueue(label: "ToolProxyTests")
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

		let listener = try NWListener(using: parameters)
		defer { listener.cancel() }

		let (accepted, continuation) = AsyncStream.makeStream(of: NWConnection.self)
		listener.newConnectionHandler = { continuation.yield($0) }
		try await listener.waitUntilReady(queue: queue)
		let port = try #require(listener.port?.rawValue)

		// Stand-ins for the proxy's stdin and stdout, whose far ends belong to claude.
		let toProxy = Pipe()
		let fromProxy = Pipe()
		let proxy = Task {
			try await Claude.ToolProxy.run(
				port: port,
				input: toProxy.fileHandleForReading,
				output: fromProxy.fileHandleForWriting)
		}

		var connections = accepted.makeAsyncIterator()
		let connection = try #require(await connections.next())
		defer { connection.cancel() }
		try await connection.waitUntilReady(queue: queue)

		// Closing before the send is what makes this deterministic: the proxy's very next write
		// has no reader left, with no timing to lose the race to.
		try fromProxy.fileHandleForReading.close()
		try await connection.send(Data("{}\n".utf8))

		try await proxy.value
	}

}
