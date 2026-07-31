import Foundation
import Network

// Starts the endpoint on the queue and suspends until it reports .ready;
// .failed and .cancelled surface as thrown errors. One-shot: the state
// handler uninstalls itself on resolution.

extension NWConnection {

	func waitUntilReady(queue: DispatchQueue) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			stateUpdateHandler = { [weak self] state in
				let outcome: Result<Void, any Error>? = switch state {
				case .ready: .success(())
				case .failed(let error): .failure(error)
				case .cancelled: .failure(CancellationError())
				default: nil
				}

				guard let outcome else { return }
				self?.stateUpdateHandler = nil
				continuation.resume(with: outcome)
			}

			start(queue: queue)
		}
	}

}

extension NWListener {

	func waitUntilReady(queue: DispatchQueue) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			stateUpdateHandler = { [weak self] state in
				let outcome: Result<Void, any Error>? = switch state {
				case .ready: .success(())
				case .failed(let error): .failure(error)
				case .cancelled: .failure(CancellationError())
				default: nil
				}

				guard let outcome else { return }
				self?.stateUpdateHandler = nil
				continuation.resume(with: outcome)
			}

			start(queue: queue)
		}
	}

}
