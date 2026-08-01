import Foundation
import Logging
import MCP

// A transport that keeps a copy of every frame the host writes. What a client hands back is already
// normalized by its decoder — a JSON null and an absent key both arrive as nil — so the only place a
// test can hold the response to the wire contract is the bytes themselves.
actor RecordingTransport: Transport {

	nonisolated let logger = Logger(label: "ClaudeKitTests.RecordingTransport", factory: { _ in SwiftLogNoOpLogHandler() })

	private let transport: InMemoryTransport
	private var incoming: AsyncThrowingStream<Data, any Swift.Error>?
	private(set) var frames: [String] = []

	init(_ transport: InMemoryTransport) {
		self.transport = transport
	}

	func connect() async throws {
		try await transport.connect()
		// `receive()` is not async, so the stream has to be taken while the actor can still await —
		// Server always connects before it receives, which makes this the one point where it can.
		incoming = await transport.receive()
	}

	func disconnect() async {
		await transport.disconnect()
	}

	func send(_ data: Data) async throws {
		frames.append(String(decoding: data, as: UTF8.self))
		try await transport.send(data)
	}

	func receive() -> AsyncThrowingStream<Data, any Swift.Error> {
		incoming ?? AsyncThrowingStream { $0.finish() }
	}
}
