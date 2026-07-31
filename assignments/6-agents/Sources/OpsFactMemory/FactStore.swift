import Foundation
import OpsCore

// In-memory durable-fact storage keyed by the identity namespace, never by thread: cross-thread recall
// is a property of the key, not of a lookup rule a caller could forget to apply. There is no API that
// takes a namespace from outside, so no caller can ask for another identity's facts — the only way in is
// a trusted RuntimeContext.
//
// Restart survival is deliberately out of scope here: an actor is enough to prove the scoping and
// gating contract, and the storage substrate is the procedures ticket's problem.
public actor FactStore {

	public static let maximumFactsPerIdentity = 512

	// The Python service's `_MAX_IDENTITIES`. The bound exists to keep one process from accumulating unbounded
	// per-identity state, not to cap how many identities a deployment may have, so inventing a smaller number
	// here would refuse writes the Python contract accepts.
	public static let maximumIdentities = 10_000

	private let namespace: FactNamespace
	private let factLimit: Int

	private var storage: [String: [Fact]] = [:]

	public init(namespace: FactNamespace, factsPerIdentity: Int = FactStore.maximumFactsPerIdentity) throws {
		guard (1...Self.maximumFactsPerIdentity).contains(factsPerIdentity) else {
			throw ContractError("fact retention must be a positive bounded integer")
		}

		self.namespace = namespace
		factLimit = factsPerIdentity
	}

	// MARK: Writes

	public func save(_ fact: Fact, context: RuntimeContext) throws {
		let scope = namespace(context)
		var facts = storage[scope] ?? []
		guard facts.count < factLimit else { throw ContractError("identity fact limit reached") }
		guard storage[scope] != nil || storage.count < Self.maximumIdentities else {
			throw ContractError("stored identity limit reached")
		}
		guard !facts.contains(where: { $0.factID == fact.factID }) else {
			throw ContractError("fact identifier collision")
		}

		facts.append(fact)
		storage[scope] = facts
	}

	// MARK: Reads

	// Ranked by how many distinct query terms the fact mentions, most recent first among equal scores. The
	// Python store ranks the same recall by embedding similarity; term overlap is the deterministic stand-in
	// for it here, and no fact without a single matching term is ever advisory enough to return.
	public func recall(_ query: String, limit: Int, context: RuntimeContext) -> [Fact] {
		let terms = query.relevanceTerms
		let ranked = (storage[namespace(context)] ?? []).enumerated()
			.map { (recency: $0.offset, score: $0.element.relevance(to: terms), fact: $0.element) }
			.filter { $0.score > 0 }
			.sorted { ($0.score, $0.recency) > ($1.score, $1.recency) }

		return ranked.prefix(limit).map(\.fact)
	}

	public func count(for context: RuntimeContext) -> Int {
		storage[namespace(context)]?.count ?? 0
	}

	public func facts(for context: RuntimeContext) -> [Fact] {
		storage[namespace(context)] ?? []
	}
}

private extension Fact {

	func relevance(to terms: Set<String>) -> Int {
		terms.intersection(text.relevanceTerms).count
	}
}

private extension String {

	var relevanceTerms: Set<String> {
		Set(lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
	}
}
