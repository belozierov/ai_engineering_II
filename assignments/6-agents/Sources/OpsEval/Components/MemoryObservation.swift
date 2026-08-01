import Foundation
import OpsCore
import OpsEvidenceGuard
import OpsFactMemory
import OpsProcedures

// The seven facts the Python evaluator's `_MemoryObservation` carries, and the four rows they decide. One
// run of the durable-memory services produces all of them, in one order, because they are not independent:
// the guarded writes have to be attempted before the real ones, and the cross-identity reads have to happen
// after the turn that wrote them ended.
struct MemoryObservation: Sendable {

	var factRecalled = false
	var procedureRecalled = false
	var procedureConflictChecked = false
	var factWriteGuarded = false
	var procedureWriteGuarded = false
	var identityIsolated = false
	var eventsSafe = false
}

// MARK: Observation

extension MemoryObservation {

	// The Python evaluator's `_PUBLIC_EVENT_FIELDS`, transcribed. It is the whole allowlist an event may
	// publish, so a field added to the envelope has to fail this rather than widen it.
	static let publicEventFields: Set<String> = [
		"schema_version", "event_type", "run_id", "status", "source_family", "memory_level", "count",
		"artifact_id", "digest"
	]

	static let factText = "Synthetic checkout uses a strict tax-service timeout."
	static let factNeedle = "strict tax-service timeout"
	static let recallQuery = "checkout tax-service timeout"
	static let procedureID = "checkout_triage"
	static let initialTitle = "Synthetic checkout triage"
	static let updatedTitle = "Updated synthetic checkout triage"
	static let conflictingTitle = "Conflicting synthetic update"
	static let step = "Inspect bounded checkout evidence."
	static let blockedFactText = "Blocked synthetic fact must not persist."
	static let blockedStep = "This procedure must not persist."
	static let blockedNeedle = "must not persist"

	static func observed(_ stack: ComponentStack) async throws -> MemoryObservation {
		let first = try ComponentContext.make(
			identity: "identity-eval-memory-a",
			thread: "thread-eval-memory-a",
			run: "run-eval-memory-a"
		)
		let sameIdentity = try ComponentContext.make(
			identity: first.identityID,
			thread: "thread-eval-memory-b",
			run: "run-eval-memory-b"
		)
		let otherIdentity = try ComponentContext.make(
			identity: "identity-eval-memory-b",
			thread: "thread-eval-memory-a",
			run: "run-eval-memory-c"
		)

		var observation = MemoryObservation()
		let written = try await observation.write(in: stack, context: first)

		let sameFacts = try await recalled(stack, context: sameIdentity)
		let otherFacts = try await recalled(stack, context: otherIdentity)
		let sameProcedure = try await read(stack, context: sameIdentity)
		let otherProcedure = try await read(stack, context: otherIdentity)

		let events = try await stack.sink.events(for: first) + stack.sink.events(for: sameIdentity)
			+ stack.sink.events(for: otherIdentity)
		let memoryLevels = Set(events.lazy.filter { $0.eventType == .memory }.compactMap(\.memoryLevel))

		observation.factRecalled = sameFacts.contains(factNeedle) && !otherFacts.contains(factNeedle)
			&& memoryLevels.contains(.fact)
		observation.procedureRecalled = sameProcedure.contains(updatedTitle)
			&& !sameProcedure.contains(conflictingTitle) && !otherProcedure.contains(updatedTitle)
			&& written.provenancePreserved && memoryLevels.contains(.procedure)
		observation.identityIsolated = Self.isolated(stack, first, sameIdentity, otherIdentity)
		observation.eventsSafe = try Self.eventsAreSafe(events)

		return observation
	}

	// MARK: Turn

	// Everything that happens while the turn is open, in the Python evaluator's order: the unusable evidence
	// is issued first so the guarded-write attempts have something to be refused for, then the real fact and
	// the real procedure land, and the conflicting update is the last thing tried.
	private mutating func write(in stack: ComponentStack, context: RuntimeContext) async throws -> Written {
		try await stack.services.registry.beginTurn(context)
		do {
			let written = try await writeInsideTurn(stack, context: context)
			_ = try await stack.services.registry.finishTurn(context)

			return written
		} catch {
			await stack.services.registry.abortTurn(context)
			throw error
		}
	}

	private mutating func writeInsideTurn(_ stack: ComponentStack, context: RuntimeContext) async throws -> Written {
		let registry = stack.services.registry
		let evidence = try await registry.issue(context, result: stack.sandbox.readFile(path: "logs/checkout.log"))
		let quarantined = try await registry.issue(
			context,
			result: stack.sandbox.readFile(path: "logs/maintenance.log")
		)
		let failed = try await registry.issue(
			context,
			result: Self.syntheticResult(.failed, sourceID: "repository:read:failed-write")
		)
		let truncated = try await registry.issue(
			context,
			result: Self.syntheticResult(.ok, sourceID: "repository:read:truncated-write", truncated: true)
		)
		let invalidIDs = [
			[quarantined.evidenceID], [failed.evidenceID], [truncated.evidenceID], ["invented-evidence-id"]
		]

		factWriteGuarded = try await Self.factWritesAreGuarded(stack, invalidIDs: invalidIDs, context: context)
		procedureWriteGuarded = try await Self.procedureWritesAreGuarded(
			stack,
			invalidIDs: invalidIDs,
			context: context
		)

		_ = try await SaveFactTool(service: stack.facts, context: context).call(
			arguments: Self.saveArguments(text: Self.factText, evidenceIDs: [evidence.evidenceID])
		)

		let write = WriteProcedureTool(memory: stack.procedures, context: context)
		let initialHash = try Self.contentHash(
			of: try await write.call(Self.procedureArguments(title: Self.initialTitle, citing: evidence))
		)
		let updatedHash = try Self.contentHash(
			of: try await write.call(
				Self.procedureArguments(title: Self.updatedTitle, citing: evidence, expectedHash: initialHash)
			)
		)
		guard updatedHash != initialHash else {
			throw ContractError("procedure update did not change its content hash")
		}

		let persisted = try await stack.procedureService.read(context, procedureID: Self.procedureID)
		do {
			_ = try await write.call(
				Self.procedureArguments(
					title: Self.conflictingTitle,
					steps: [Self.blockedStep],
					citing: evidence,
					expectedHash: initialHash
				)
			)
		} catch let error as ProcedureStoreError where error.isConflict {
			procedureConflictChecked = true
		}

		return Written(provenancePreserved: persisted?.provenance == [evidence.provenance])
	}

	private struct Written {

		let provenancePreserved: Bool
	}
}

// MARK: Guarded writes

private extension MemoryObservation {

	// Ported from `_fact_writes_are_guarded`: every unusable citation is refused, the identity's stored facts
	// are byte for byte what they were, and nothing the refused writes carried comes back from a recall.
	//
	// One read-back rather than the Python evaluator's two: provenance lives inside the Fact record here
	// instead of in a namespace of its own, so the facts themselves already carry everything a second
	// namespace read would have shown.
	static func factWritesAreGuarded(
		_ stack: ComponentStack,
		invalidIDs: [[String]],
		context: RuntimeContext
	) async throws -> Bool {
		let save = SaveFactTool(service: stack.facts, context: context)
		let before = await stack.factStore.facts(for: context)

		for evidenceIDs in invalidIDs {
			do {
				_ = try await save.call(arguments: saveArguments(text: blockedFactText, evidenceIDs: evidenceIDs))

				return false
			} catch is EvidenceActionBlocked {
				continue
			}
		}

		let after = await stack.factStore.facts(for: context)
		let recalled = try await recalled(stack, context: context, query: "blocked synthetic fact")

		return before == after && !recalled.lowercased().contains(blockedNeedle)
	}

	// Ported from `_procedure_writes_are_guarded`: each refused write leaves no record behind it under its own
	// identifier, and the identity's inventory is unchanged at the end.
	static func procedureWritesAreGuarded(
		_ stack: ComponentStack,
		invalidIDs: [[String]],
		context: RuntimeContext
	) async throws -> Bool {
		let write = WriteProcedureTool(memory: stack.procedures, context: context)
		let read = ReadProcedureTool(memory: stack.procedures, context: context)
		let before = try await stack.procedureService.list(context)

		for (index, evidenceIDs) in invalidIDs.enumerated() {
			let procedureID = "blocked_checkout_\(index)"
			do {
				_ = try await write.call(
					WriteProcedureTool.Arguments(
						procedureID: procedureID,
						title: "Blocked synthetic procedure",
						steps: [blockedStep],
						evidenceIDs: evidenceIDs
					)
				)

				return false
			} catch is EvidenceActionBlocked {}

			let persisted = try await read.payload(ReadProcedureTool.Arguments(procedureID: procedureID))
			guard !persisted.lowercased().contains(blockedNeedle) else { return false }
		}

		return try await stack.procedureService.list(context) == before
	}
}

// MARK: Reads

private extension MemoryObservation {

	static func recalled(
		_ stack: ComponentStack,
		context: RuntimeContext,
		query: String = MemoryObservation.recallQuery
	) async throws -> String {
		try await RecallFactsTool(service: stack.facts, context: context).payload(
			arguments: #"{"query":"\#(query)","limit":5}"#
		)
	}

	static func read(_ stack: ComponentStack, context: RuntimeContext) async throws -> String {
		try await ReadProcedureTool(memory: stack.procedures, context: context).payload(
			ReadProcedureTool.Arguments(procedureID: procedureID)
		)
	}
}

// MARK: Assessment

private extension MemoryObservation {

	// The identity claim, in the two derivations that decide it. Facts are keyed by identity alone, so one
	// identity reaches its own namespace from any thread and no identity reaches another's; the event view is
	// keyed by the whole trusted triple, so two identities sharing a thread identifier still see nothing of
	// each other's runs.
	static func isolated(
		_ stack: ComponentStack,
		_ first: RuntimeContext,
		_ sameIdentity: RuntimeContext,
		_ otherIdentity: RuntimeContext
	) -> Bool {
		let secret = stack.identity.secret

		return stack.factNamespace(first) == stack.factNamespace(sameIdentity)
			&& stack.factNamespace(first) != stack.factNamespace(otherIdentity)
			&& ComponentContext.eventViewScope(of: first, secret: secret)
				!= ComponentContext.eventViewScope(of: otherIdentity, secret: secret)
	}

	// Every event this run emitted, put through the one serializer anything leaving the process goes through:
	// each has to publish, each has to stay inside the allowlist, and the durable fact's own text must appear
	// in none of them.
	static func eventsAreSafe(_ events: [AppEvent]) throws -> Bool {
		let encoder = PublicEventEncoder()
		let published = try events.map(encoder.json(for:))
		let fields = try published.map(ComponentJSON.fieldNames(of:))

		return !published.isEmpty && published.count == events.count
			&& fields.allSatisfy { $0.isSubset(of: publicEventFields) }
			&& fields.allSatisfy { !$0.contains("content") }
			&& !published.contains { $0.contains(factText) }
	}
}

// MARK: Fixtures

private extension MemoryObservation {

	// The two unusable results the sandbox cannot produce on its own: a read that failed outright and one that
	// came back partial. Both are issued as evidence and both have to be refused by every durable write.
	static func syntheticResult(
		_ status: SourceStatus,
		sourceID: String,
		truncated: Bool = false
	) throws -> SourceResult {
		let content = status == .ok ? "bounded partial evidence" : ""

		return try SourceResult(
			sourceFamily: .repository,
			sourceID: sourceID,
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			truncated: truncated
		)
	}

	static func saveArguments(text: String, evidenceIDs: [String]) -> String {
		let identifiers = evidenceIDs.map { #""\#($0)""# }.joined(separator: ",")

		return #"{"text":"\#(text)","evidence_ids":[\#(identifiers)]}"#
	}

	static func procedureArguments(
		title: String,
		steps: [String] = [MemoryObservation.step],
		citing evidence: Evidence,
		expectedHash: String? = nil
	) -> WriteProcedureTool.Arguments {
		WriteProcedureTool.Arguments(
			procedureID: procedureID,
			title: title,
			steps: steps,
			evidenceIDs: [evidence.evidenceID],
			expectedHash: expectedHash
		)
	}

	// Mirrors `_procedure_content_hash`: a write that does not hand back a well-formed digest has not given
	// the caller what the next update needs, whatever else it did.
	static func contentHash(of output: WriteProcedureTool.Output) throws -> String {
		try output.contentHash.validatedDigest("procedure content hash")
	}
}
