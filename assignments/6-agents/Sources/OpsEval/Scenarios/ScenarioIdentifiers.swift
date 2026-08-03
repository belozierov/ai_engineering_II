import Foundation
import OpsAgent
import OpsEvidenceGuard
import Synchronization

// The identifier sequences one scenario run mints, and the only way a scripted conversation can cite
// anything. A citation has to be written into the script before the run exists, so the evidence a
// scripted answer names is decided here — `evidence(1)` is the first source the run reads, `evidence(2)`
// the second — and the run is composed with generators that hand out exactly those.
//
// Determinism is confined to the identifier sequences. Identity still comes from the store, the scope
// secret is still the identity's, and no digest, port or workspace path is fixed by this.
struct ScenarioIdentifiers: Sendable {

	let prefix: String

	var agentIdentifiers: AgentIdentifiers {
		AgentIdentifiers(
			run: Self.counting("run-\(prefix)"),
			evidence: Self.counting("evidence-\(prefix)"),
			plan: Self.counting("plan-\(prefix)"),
			compaction: Self.counting("compaction-\(prefix)")
		)
	}

	func evidence(_ index: Int) -> String { "evidence-\(prefix)-\(index)" }

	func citation(_ index: Int) -> String { Citation.text(evidence(index)) }

	private static func counting(_ prefix: String) -> AgentIdentifiers.Generator {
		let counter = Counter()

		return { "\(prefix)-\(counter.next())" }
	}
}

// MARK: Counter

// A reference type because a Mutex is non-copyable and an escaping generator has to capture something:
// the class is the handle, the mutex stays put behind it.
private final class Counter: Sendable {

	private let issued = Mutex(0)

	func next() -> Int {
		issued.withLock { count in
			count += 1

			return count
		}
	}
}
