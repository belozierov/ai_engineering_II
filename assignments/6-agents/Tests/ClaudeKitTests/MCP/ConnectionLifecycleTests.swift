import Foundation
import Network
import Testing

@testable import ClaudeKit

@Suite("ToolHost connection lifecycle")
struct ConnectionLifecycleTests {

	// One descriptor per turn used to leak: the peer-closed exit of the receive loop
	// finished the stream but never cancelled the NWConnection, so every claude -p
	// turn's connection kept its socket until process exit. Cycles use a bare TCP
	// client — pipes and an MCP client would add their own slow-releasing descriptors
	// and drown the signal.
	@Test
	func peerClosedConnectionsReleaseDescriptors() async throws {
		let host = try ToolHost(tools: [EchoTool()])
		let port = try await host.start()
		let queue = DispatchQueue(label: "ConnectionLifecycleTests")

		// Warm-up cycle absorbs Network.framework's one-time lazy allocations.
		try await cycle(port: port, queue: queue)
		try await Task.sleep(for: .milliseconds(200))

		let baseline = openDescriptorCount()
		let cycles = 5
		for _ in 0..<cycles {
			try await cycle(port: port, queue: queue)
		}

		// Cancelled connections release their sockets asynchronously — poll, then assert.
		var current = openDescriptorCount()
		for _ in 0..<20 where current > baseline {
			try await Task.sleep(for: .milliseconds(100))
			current = openDescriptorCount()
		}

		#expect(current <= baseline, "Descriptors grew \(baseline) → \(current) across \(cycles) connection cycles")
		await host.stop()
	}

	// MARK: Helpers

	private func cycle(port: UInt16, queue: DispatchQueue) async throws {
		let connection = NWConnection(
			host: "127.0.0.1",
			port: NWEndpoint.Port(rawValue: port)!,
			using: .tcp)
		try await connection.waitUntilReady(queue: queue)

		// Give the host a moment to enter its serve path before the peer-close arrives.
		try await Task.sleep(for: .milliseconds(50))
		connection.cancel()
	}

	private func openDescriptorCount() -> Int {
		(try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
	}

}
