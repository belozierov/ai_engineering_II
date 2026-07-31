import Foundation
import OpsCore
import OpsEvidenceGuard

// Procedure memory as the agent is allowed to use it: the store plus the two policies that must hold
// around every write. A write needs usable evidence from the current run, and the provenance the guard
// returns — not the evidence identifiers, which expire with the turn — is what gets persisted with the
// record. Nothing else may reach the store, so this is the only type the tools and the loop talk to.
//
// The order is the point: the guard runs first and the store is never touched when it refuses, so a
// rejected write cannot create a workspace, a temporary file or an inventory entry.
public struct ProcedureMemory: Sendable {

	private let service: SecureProcedureService
	private let evidenceGuard: EvidenceGuard
	private let sink: any EventSink
	private let events = MetadataEventFactory()

	public init(service: SecureProcedureService, evidenceGuard: EvidenceGuard, sink: any EventSink) {
		self.service = service
		self.evidenceGuard = evidenceGuard
		self.sink = sink
	}

	// MARK: Reads

	public func list(_ context: RuntimeContext) async throws -> [String] {
		let identifiers = try await service.list(context)
		await emit(context, status: .completed, count: identifiers.count)

		return identifiers
	}

	// Recall is advisory: what comes back is durable untrusted data with no citation attached to it, and
	// this method is the last place that could pretend otherwise — it returns the record, never evidence.
	public func read(_ context: RuntimeContext, procedureID: String) async throws -> Procedure? {
		let procedure = try await service.read(context, procedureID: procedureID)
		await emit(context, status: .completed, count: procedure == nil ? 0 : 1, artifactID: procedureID)

		return procedure
	}

	// MARK: Writes

	public func write(
		_ context: RuntimeContext,
		procedureID: String,
		title: String,
		steps: [String],
		evidenceIDs: [String],
		expectedHash: String? = nil
	) async throws -> Written {
		let provenance: [ProvenanceRef]
		do {
			provenance = try await evidenceGuard.validateAction(.writeProcedure, evidenceIDs: evidenceIDs, context: context)
		} catch {
			await emit(context, status: .blocked, count: 0, artifactID: procedureID)

			throw error
		}

		do {
			// The boundary composes model text to NFC before it becomes a record, which is what the Python tool
			// layer does and what makes the record type's "must already be composed" rule unreachable from here.
			// A step spelled with a combining accent is the same step, and refusing it would cost the model a
			// write over a difference it cannot see in its own output.
			let procedure = try Procedure(
				procedureID: procedureID,
				title: title.canonicallyComposed,
				steps: steps.map(\.canonicallyComposed),
				provenance: provenance
			)
			let contentHash = try await service.write(context, procedure, expectedHash: expectedHash)
			await emit(context, status: .completed, count: 1, artifactID: procedureID)

			return Written(procedure: procedure, contentHash: contentHash)
		} catch {
			await emit(context, status: .failed, count: 0, artifactID: procedureID)

			throw error
		}
	}

	// MARK: Events

	// Metadata only, and deliberately unable to fail the operation it describes: a write that has already
	// landed must not be reported to its caller as an error because the sink refused the event. An artifact
	// identifier is attached only when it is a valid one, so a malformed procedure identifier surfaces as
	// the validation error it is instead of as an event-construction failure.
	private func emit(_ context: RuntimeContext, status: EventStatus, count: Int, artifactID: String? = nil) async {
		let identifier = artifactID.flatMap { try? $0.validatedIdentifier("procedure artifact identifier") }
		guard let event = try? events.memory(
			context,
			level: .procedure,
			status: status,
			count: count,
			artifactID: identifier
		) else {
			return
		}

		try? await sink.emitScoped(context, event)
	}
}

// MARK: Written record

public extension ProcedureMemory {

	struct Written: Hashable, Sendable {

		public let procedure: Procedure
		public let contentHash: String
	}
}
