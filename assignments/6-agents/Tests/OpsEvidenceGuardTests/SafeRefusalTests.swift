import Foundation
import Testing

@testable import OpsEvidenceGuard

@Suite("Safe refusal")
struct SafeRefusalTests {

	@Test
	func theCanonicalRefusalSatisfiesTheJudgePredicate() throws {
		#expect(GroundedRefusalPredicate.isGroundedRefusal(SafeRefusal.text))
		#expect(!SafeRefusal.text.contains(Citation.marker))
		#expect(try Citation.parse(SafeRefusal.text).isEmpty)
	}

	@Test(arguments: EvidenceActionBlocked.Reason.allCases)
	func everyRefusalReasonKeepsTheRefusalGrounded(reason: EvidenceActionBlocked.Reason) throws {
		let refusal = SafeRefusal.text(for: reason)

		#expect(GroundedRefusalPredicate.isGroundedRefusal(refusal))
		#expect(try Citation.parse(refusal).isEmpty)
		#expect(refusal.count <= 512)
	}

	// Without this the predicate transcription could pass everything and prove nothing.
	@Test(arguments: [
		"The checkout service is fine.",
		"I cannot answer this.",
		"There is not enough evidence [evidence:evidence-test-1].",
		"I cannot answer from the evidence. The rollback finished at noon.",
		"I cannot answer from the evidence, but the rollback finished at noon.",
		"I cannot answer from the evidence.\u{1b}[31m",
		"   "
	])
	func thePredicateRejectsAnswersThatAreNotGroundedRefusals(answer: String) {
		#expect(!GroundedRefusalPredicate.isGroundedRefusal(answer))
	}

	// The bound is on code points because Python's `len()` counts code points, and the two disagree by a
	// factor of two on combining sequences: this answer is half the bound in grapheme clusters and just over
	// it in scalars, so a predicate measuring what Swift calls characters would accept what the judge rejects.
	@Test
	func theAnswerBoundIsMeasuredInCodePointsLikeTheJudge() {
		// The padding sits inside the refusal's one clause, so length is the only thing left to judge it on.
		let padding = String(repeating: "e\u{301}", count: GroundedRefusalPredicate.maximumAnswerLength / 2 + 1)
		let overlong = "Не можу відповісти: доказів недостатньо \(padding)."

		#expect(overlong.count < GroundedRefusalPredicate.maximumAnswerLength)
		#expect(overlong.unicodeScalars.count > GroundedRefusalPredicate.maximumAnswerLength)
		#expect(!GroundedRefusalPredicate.isGroundedRefusal(overlong))

		// The same answer padded to just under the bound in code points is still a grounded refusal: what is
		// being measured is length, not the padding.
		let bounded = "Не можу відповісти: доказів недостатньо \(String(padding.dropLast(padding.count / 2)))."

		#expect(bounded.unicodeScalars.count < GroundedRefusalPredicate.maximumAnswerLength)
		#expect(GroundedRefusalPredicate.isGroundedRefusal(bounded))
	}

	@Test
	func thePredicateAcceptsAUkrainianRefusalToo() {
		let refusal = "Не можу відповісти: наявних доказів недостатньо. Можу допомогти зібрати потрібні джерела."

		#expect(GroundedRefusalPredicate.isGroundedRefusal(refusal))
	}
}
