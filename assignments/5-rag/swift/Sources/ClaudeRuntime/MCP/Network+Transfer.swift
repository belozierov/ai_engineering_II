// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation
import Network

// Async single-shot bridges over NWConnection's callback API, shared by the proxy
// pumps and the host transport. Interpretation of the chunk (EOF handling, framing)
// stays with the caller.

extension NWConnection {

	// Receives whatever bytes are available (1...64KB); `isCompleted` marks the peer's EOF.
	func receiveChunk() async throws -> (data: Data?, isCompleted: Bool) {
		try await withCheckedThrowingContinuation { continuation in
			receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isCompleted, error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: (data, isCompleted))
				}
			}
		}
	}

	func send(_ data: Data) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			send(content: data, completion: .contentProcessed { error in
				error.map { continuation.resume(throwing: $0) } ?? continuation.resume()
			})
		}
	}

}
