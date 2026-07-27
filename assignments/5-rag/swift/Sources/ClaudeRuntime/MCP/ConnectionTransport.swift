// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation
import Network
import Logging
import MCP

// Newline-framed JSON-RPC over an accepted NWConnection — the byte stream must stay
// exactly what claude's stdio side expects, since the proxy pipes it verbatim.
actor ConnectionTransport: Transport {

	private enum State {
		case idle, connecting, connected, cancelled
	}

	nonisolated let logger: Logger

	private let connection: NWConnection
	private let queue: DispatchQueue
	private var state = State.idle

	private let messageStream: AsyncThrowingStream<Data, any Error>
	private let messageContinuation: AsyncThrowingStream<Data, any Error>.Continuation

	init(connection: NWConnection, queue: DispatchQueue, logger: Logger) {
		self.connection = connection
		self.queue = queue
		self.logger = logger
		(messageStream, messageContinuation) = AsyncThrowingStream.makeStream()
	}

	// MARK: Transport

	func connect() async throws {
		guard state == .idle else { return }
		state = .connecting

		try await connection.waitUntilReady(queue: queue)

		state = .connected
		Task { await receiveLoop() }
	}

	func disconnect() async {
		state = .cancelled
		connection.cancel()
		messageContinuation.finish()
	}

	func send(_ message: Data) async throws {
		guard state == .connected else { throw MCPError.internalError("Not connected") }

		var data = message
		data.append(UInt8(ascii: "\n"))

		try await connection.send(data)
	}

	func receive() -> AsyncThrowingStream<Data, any Error> {
		messageStream
	}

	// MARK: Receiving

	private func receiveLoop() async {
		var buffer = Data()

		while state == .connected {
			do {
				let data = try await receiveData()
				guard !data.isEmpty else { continue }
				buffer.append(data)

				while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
					let message = buffer[..<newlineIndex]
					buffer = Data(buffer[(newlineIndex + 1)...])

					if !message.isEmpty {
						messageContinuation.yield(Data(message))
					}
				}

			} catch {
				// The peer closing the connection is the normal end of a claude run, not a failure.
				if state == .connected, (error as? MCPError) != .connectionClosed {
					logger.error("Receive error: \(error)")
				}
				break
			}
		}

		messageContinuation.finish()

		// The read side ending must release the socket: an NWConnection that is never
		// cancelled keeps its descriptor for the process lifetime — one leak per
		// claude -p turn, since the CLI driver opens a fresh connection per send.
		state = .cancelled
		connection.cancel()
	}

	private func receiveData() async throws -> Data {
		let (data, isCompleted) = try await connection.receiveChunk()
		if let data { return data }
		if isCompleted { throw MCPError.connectionClosed }
		return Data()
	}

}
