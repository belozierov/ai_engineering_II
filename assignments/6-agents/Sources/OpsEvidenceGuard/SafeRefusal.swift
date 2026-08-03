import Foundation

// The one terminal answer this policy is allowed to invent. It has to read as a plain refusal to a user
// and still satisfy the evaluator's grounded-refusal predicate, which is stricter than it looks: the text
// carries no citation marker, states the denial and the missing grounding, and every clause — the
// predicate splits on sentence punctuation and on contrastive conjunctions — independently mentions a
// denial, the evidence, or an offer of help. Reword only against the transcribed predicate test.
public enum SafeRefusal {

	public static let text = """
		I cannot answer this from the evidence available in this turn. \
		The sources I retrieved are insufficient to support a grounded answer. \
		I can outline which additional sources would settle it and collect more once you point me at them.
		"""

	public static func text(for reason: EvidenceActionBlocked.Reason) -> String {
		"""
		I cannot answer this from the evidence available in this turn. \
		The evidence policy rejected the answer because \(reason.explanation). \
		I can outline which additional sources would settle it and collect more once you point me at them.
		"""
	}
}
