import Foundation
import OpsCore
import OpsEvidenceGuard

// The fact-memory policy boundary: a durable write happens only behind the evidence guard, and a recall
// never comes back as authority. Everything the tools do goes through here, so the two rules hold no
// matter which interface is calling.
//
// Nothing here touches the store before the guard has spoken: validation is complete — bounded text,
// usable current-run evidence — before the first mutation, so a blocked save leaves the identity's facts
// byte-for-byte as they were.
public struct FactMemoryService: Sendable {

	public typealias IdentifierGenerator = @Sendable () throws -> String

	public static let maximumQueryLength = 500
	public static let defaultRecallLimit = 5
	public static let recallLimits = 1...10

	private let store: FactStore
	private let guardrail: EvidenceGuard
	private let events: any EventSink
	private let newID: IdentifierGenerator
	private let eventFactory = MetadataEventFactory()

	public init(
		store: FactStore,
		guardrail: EvidenceGuard,
		events: any EventSink,
		newID: @escaping IdentifierGenerator
	) {
		self.store = store
		self.guardrail = guardrail
		self.events = events
		self.newID = newID
	}

	// MARK: Writes

	// What survives the turn is the provenance the guard returns, never the cited evidence identifiers:
	// provenance explains where a fact came from, an evidence identifier is a permission that expires.
	public func save(text: String, evidenceIDs: [String], context: RuntimeContext) async throws -> Fact {
		let text = try text.validatedMemoryText("fact text", maximum: Fact.maximumTextLength)
		let provenance = try await validatedProvenance(evidenceIDs, context: context)
		let fact = try Fact(factID: newID(), text: text, provenance: provenance)

		try await store.save(fact, context: context)
		await emit(.completed, count: 1, artifactID: fact.factID, context: context)

		return fact
	}

	// MARK: Reads

	// Recalled facts are advisory untrusted data by construction: this returns records the store already
	// holds and issues nothing, so no current-run evidence exists afterwards that did not exist before.
	public func recall(query: String, limit: Int = FactMemoryService.defaultRecallLimit, context: RuntimeContext)
		async throws -> [Fact] {
		let query = try query.validatedMemoryText("fact query", maximum: Self.maximumQueryLength)
		guard Self.recallLimits.contains(limit) else { throw ContractError("fact recall limit must be bounded") }

		let facts = await store.recall(query, limit: limit, context: context)
		await emit(.completed, count: facts.count, context: context)

		return facts
	}

	// MARK: Policy

	private func validatedProvenance(_ evidenceIDs: [String], context: RuntimeContext) async throws -> [ProvenanceRef] {
		do {
			return try await guardrail.validateAction(.writeFact, evidenceIDs: evidenceIDs, context: context)
		} catch {
			await emit(.blocked, count: 0, context: context)

			throw error
		}
	}

	// MARK: Events

	// Metadata only, and deliberately unable to fail the operation it describes. A fact that has already
	// landed in the store must not be reported to its caller as an error because the sink refused the event:
	// the caller would retry a write that already happened and either duplicate the fact or collide with its
	// own identifier. The same reasoning covers a denial — a sink that cannot record the block must not
	// replace the block with its own error — so both directions get the same best-effort emission.
	private func emit(
		_ status: EventStatus,
		count: Int,
		artifactID: String? = nil,
		context: RuntimeContext
	) async {
		guard let event = try? eventFactory.memory(
			context,
			level: .fact,
			status: status,
			count: count,
			artifactID: artifactID
		) else {
			return
		}

		try? await events.emitScoped(context, event)
	}
}
