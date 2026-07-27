// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation
import Network

extension Claude {

	public enum ToolProxy {

		public enum Errors: Error {
			case portNotConfigured(variable: String)
			case invalidPort(String)
		}

		public static func run() async throws {
			let variable = ToolProxyCommand.portEnvironmentVariable
			guard let value = ProcessInfo.processInfo.environment[variable] else {
				throw Errors.portNotConfigured(variable: variable)
			}
			guard let port = UInt16(value) else { throw Errors.invalidPort(value) }
			try await run(port: port)
		}

		public static func run(
			port: UInt16,
			input: FileHandle = .standardInput,
			output: FileHandle = .standardOutput) async throws {
			guard let port = NWEndpoint.Port(rawValue: port) else { throw Errors.invalidPort("\(port)") }
			let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: .tcp)
			defer { connection.cancel() }

			try await connection.waitUntilReady(queue: DispatchQueue(label: "ClaudeMCP.ToolProxy"))

			// Either side closing ends the proxy: socket EOF when the host shuts down,
			// stdin EOF when claude exits. Cancellation tears the other pump down with it.
			try await withThrowingTaskGroup { group in
				group.addTask { try await pump(from: connection, to: output) }
				group.addTask { try await pump(from: input, to: connection) }
				defer { group.cancelAll() }
				try await group.next()
			}
		}

		// MARK: Pumps

		@concurrent private static func pump(from connection: NWConnection, to output: FileHandle) async throws {
			while true {
				let (data, isCompleted) = try await connection.receiveChunk()
				if let data, !data.isEmpty { try output.write(contentsOf: data) }
				if isCompleted { return }
			}
		}

		@concurrent private static func pump(from input: FileHandle, to connection: NWConnection) async throws {
			for await data in chunks(from: input) {
				try await connection.send(data)
			}
		}

		// A blocking `availableData` loop would park a cooperative-pool thread per proxy —
		// a dozen concurrent proxies in tests starved the pool and deadlocked the process.
		// The readability handler delivers chunks on Foundation's own reader queue instead,
		// where `availableData` returns immediately; an empty chunk is EOF.
		private static func chunks(from input: FileHandle) -> AsyncStream<Data> {
			AsyncStream { continuation in
				input.readabilityHandler = { handle in
					let data = handle.availableData
					guard !data.isEmpty else {
						handle.readabilityHandler = nil
						return continuation.finish()
					}
					continuation.yield(data)
				}
				continuation.onTermination = { _ in input.readabilityHandler = nil }
			}
		}

	}

}
