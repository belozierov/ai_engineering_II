import Foundation
import OpsCore

// The single registry capability the policy needs. Narrowing it to resolution keeps the guard unable to
// issue, finish or abort a turn, and it lets the policy be exercised against resolutions the real
// registry cannot produce — a record leaking in from another identity or run.
public protocol EvidenceResolver: Sendable {

	func resolve(_ context: RuntimeContext, evidenceID: String) async -> EvidenceResolution
}

extension TurnEvidenceRegistry: EvidenceResolver {}
