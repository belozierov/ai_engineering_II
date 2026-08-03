import Foundation
import OpsCore
import OpsEvidenceGuard

// Only the public outcomes the three scenario rows are decided on, in the shape the Python evaluator's
// `ReplanObservation` carries them. Reducing a run to this first is what keeps the assessment a function
// of what was published: a row can be argued about by constructing the observation, without a console, a
// fixture server or a workspace anywhere near it.
struct ReplanObservation: Sendable {

	var completed = false
	var planDigests: [String] = []
	var sourceFamilies: Set<SourceFamily> = []
	var citedFamilies: Set<SourceFamily> = []
	var citationsValid = false
	var deadEndBeforeReplan = false
	var claimsSupported = false
	var planningContextObserved = false
}

// MARK: Derivation

extension ReplanObservation {

	init(_ run: ScenarioRun, expecting claim: String) {
		self.init()

		planningContextObserved = run.promptCarries(ScenarioPromptMarker.untrustedPlanFraming)
		let events = run.transcript.events
		sourceFamilies = Set(events.lazy.filter(\.isCompletedSource).compactMap(\.sourceFamily))
		planDigests = events.filter(\.isCompletedPlanSnapshot).compactMap(\.digest)
		deadEndBeforeReplan = Self.deadEndPrecededReplan(in: run.transcript)

		guard let result = run.transcript.turnResult else { return }

		completed = result.isCompleted
		claimsSupported = result.answer.claim(matches: claim)
		// The guard already ruled on these citations while the turn was open — an answer that failed it
		// would have come back as the policy's refusal instead. What is left to read off the published
		// record is which families the accepted citations reached, so the tokens are parsed with the
		// guard's own scanner and resolved against the evidence the run reported issuing.
		let citations = (try? Citation.parse(result.answer)) ?? []
		let resolved = result.families(of: citations)
		citedFamilies = Set(resolved ?? [])
		citationsValid = completed && !citations.isEmpty && resolved != nil
	}

	// The causal claim, positionally: the dead-end source landed strictly between the first plan and the
	// second. A replan that merely happened in the same run says nothing about why it happened.
	private static func deadEndPrecededReplan(in transcript: ScenarioTranscript) -> Bool {
		let events = transcript.events
		let deadEndEvidence = transcript.turnResult?.evidenceIDs(from: MonitoringResource.deadEnd.sourceID) ?? []
		let planPositions = events.indices.filter { events[$0].isCompletedPlanSnapshot }
		let deadEndPositions = events.indices.filter { index in
			guard events[index].isCompletedSource, let artifactID = events[index].artifactID else { return false }

			return deadEndEvidence.contains(artifactID)
		}

		guard planPositions.count >= 2, let deadEnd = deadEndPositions.first else { return false }

		return planPositions[0] < deadEnd && deadEnd < planPositions[1]
	}
}

// MARK: Assessment

extension ReplanObservation {

	static let requiredSourceFamilies: Set<SourceFamily> = [.monitoring, .repository, .runbook]
	static let requiredCitedFamilies = 2

	// The three rows are one function of one observation, and they are produced together whatever it
	// says: a scenario that could not run at all still owes the ledger a verdict on each capability.
	func results() throws -> [CheckResult] {
		[
			try Self.observed(
				.scenarioReplanning,
				plansChanged,
				pass: "successful plan revision followed the observed monitoring dead end",
				fail: "a plan revision causally following the monitoring dead end was not observed",
				capabilities: [.planning, .replanning]
			),
			try Self.observed(
				.scenarioSourceFamilies,
				Self.requiredSourceFamilies.isSubset(of: sourceFamilies),
				pass: "repository monitoring and runbook outcomes observed",
				fail: "one or more required source-family outcomes were not observed",
				capabilities: [.repository, .monitoring, .runbook]
			),
			try Self.observed(
				.scenarioTwoFamilyGrounding,
				twoFamilyGrounded,
				pass: "current-run citations span a valid source-family subset",
				fail: "current-run two-family grounding was not observed",
				capabilities: [.twoFamilyGrounding, .evidenceIssuanceCitationRefusal]
			)
		]
	}

	private var plansChanged: Bool {
		completed && planDigests.count >= 2 && Set(planDigests).count >= 2
			&& deadEndBeforeReplan && planningContextObserved
	}

	private var twoFamilyGrounded: Bool {
		completed && citationsValid && claimsSupported
			&& citedFamilies.count >= Self.requiredCitedFamilies && citedFamilies.isSubset(of: sourceFamilies)
	}

	private static func observed(
		_ name: CoreCheckName,
		_ passed: Bool,
		pass: String,
		fail: String,
		capabilities: [Capability]
	) throws -> CheckResult {
		passed
			? try CheckResult.pass(name.rawValue, message: pass, capabilities: capabilities)
			: try CheckResult.fail(name.rawValue, message: fail, capabilities: capabilities)
	}
}

// MARK: Claim text

private extension String {

	// Mirrors `_expected_replan_claims_supported`: the citations come off with the whitespace that
	// introduced them, and a trailing period on either side is not a difference of substance.
	func claim(matches expected: String) -> Bool {
		withoutCitations.withoutTrailingPeriods.lowercased() == expected.withoutTrailingPeriods.lowercased()
	}

	// Computed rather than stored because `Regex` is not Sendable, and one answer is scanned once.
	private var withoutCitations: String {
		replacing(/\s*\[evidence:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\]/, with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var withoutTrailingPeriods: String {
		var text = Substring(self)
		while text.hasSuffix(".") { text = text.dropLast() }

		return String(text)
	}
}
