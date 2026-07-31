import ClaudeCLI
import ClaudeDomain
import Foundation
import OpsCompaction
import OpsCore
import Synchronization

// The live session, with exactly one moving part: which Claude.Session the sends currently go to.
// Everything else — the configuration, the factory, where transcripts live — is fixed for the
// session's life, because a derived session is that same configuration resumed on a different
// transcript.
//
// An actor rather than a struct, for two reasons. The pointer moves, and the move has to be ordered
// against the sends around it: `send` chains every call behind its predecessor and resolves the
// pointer only when its turn comes, so a send queued before a swap still runs on the old session and
// one queued after runs on the new one. The identifier lives beside that state in a mutex so `id`
// stays the synchronous read the transport protocol asks for.
actor ClaudeModelSession: CompactableModelSession {

	private let configuration: Claude.SessionConfiguration
	private let factory: CLISessionFactory
	private let transcripts: SessionTranscripts
	private nonisolated let identifier: Mutex<UUID>

	private var session: any Claude.Session
	private var lastSend: Task<Claude.SessionResult, any Error>?
	// The read `history()` served. `adopt` splices out of these very records, because the plan's
	// indices were computed against them.
	private var reading: SessionTranscripts.Reading?

	init(configuration: Claude.SessionConfiguration, factory: CLISessionFactory, transcripts: SessionTranscripts) {
		let session = factory.create(configuration, origin: .new)
		self.configuration = configuration
		self.factory = factory
		self.transcripts = transcripts
		self.session = session
		identifier = Mutex(session.id)
	}

	nonisolated var id: UUID { identifier.withLock { $0 } }

	// MARK: ModelSession

	func send(_ input: String) async throws -> Claude.SessionResult {
		let previous = lastSend
		let task = Task {
			_ = try? await previous?.value

			return try await self.dispatch(input)
		}
		lastSend = task

		return try await task.value
	}

	private func dispatch(_ input: String) async throws -> Claude.SessionResult {
		try await session.send(input)
	}

	// MARK: CompactableModelSession

	func history() throws -> [MessageGroup] {
		let reading = try transcripts.read(session.id)
		self.reading = reading

		return MessageGroup.grouping(reading.transcript.records)
	}

	func adopt(_ plan: CompactionPlan) async throws {
		// Nothing may be in flight over the pointer while it moves; a failed predecessor releases the
		// swap rather than blocking it, exactly as it releases the next send.
		_ = try? await lastSend?.value

		guard let reading else {
			throw ContractError("compaction must adopt against the history it planned from")
		}
		// Dropped up front: whatever happens next, the next plan gets a fresh read rather than one taken
		// before a swap that may or may not have happened.
		self.reading = nil

		let derived = try transcripts.derived(from: reading, plan: plan)
		// Everything above only read. From here the swap is two assignments and no failure path — the
		// old Claude.Session is dropped, never mutated.
		session = factory.create(configuration, origin: .resume(sessionID: derived.id))
		identifier.withLock { $0 = derived.id }
	}
}
