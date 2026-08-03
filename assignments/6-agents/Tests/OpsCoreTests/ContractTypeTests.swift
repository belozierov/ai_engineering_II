import Foundation
import Testing

@testable import OpsCore

@Suite("Contract value types")
struct ContractTypeTests {

	@Test
	func tokenBudgetsRejectViolatedInvariants() throws {
		let budgets = try TokenBudgets()

		#expect(budgets.compactionTarget == 4_000)
		#expect(budgets.compactionSoft == 8_000)
		#expect(budgets.hardInput == 12_000)
		#expect(budgets.responseReserve == 2_000)
		#expect(throws: ContractError.self) { try TokenBudgets(compactionTarget: 0) }
		#expect(throws: ContractError.self) { try TokenBudgets(hardInput: 1_000_001) }
		#expect(throws: ContractError.self) { try TokenBudgets(compactionTarget: 900, compactionSoft: 800) }
		#expect(throws: ContractError.self) { try TokenBudgets(compactionSoft: 13_000) }
		#expect(throws: ContractError.self) { try TokenBudgets(responseReserve: 12_000) }
	}

	@Test
	func runtimeContextsRequireBoundedTrustedIdentifiers() throws {
		let context = try Fixture.context()

		#expect(context.channel == .evaluator)
		#expect(context.allowedResources == nil)
		#expect(context.scopeIdentifiers == ["identity-test-a", "thread-test-a", "run-test-1"])
		#expect(throws: ContractError.self) { try Fixture.context(identity: "../other") }
		#expect(throws: ContractError.self) { try Fixture.context(thread: "") }
		#expect(throws: ContractError.self) { try Fixture.context(run: String(repeating: "r", count: 129)) }
		#expect(throws: ContractError.self) {
			try RuntimeContext(identityID: "identity-test-a", threadID: "thread-test-a", runID: "run-test-1",
				allowedResources: ["repository:one", "repository:one"])
		}
		#expect(throws: ContractError.self) {
			try RuntimeContext(identityID: "identity-test-a", threadID: "thread-test-a", runID: "run-test-1",
				allowedResources: ["database:one"])
		}
		#expect(throws: Never.self) {
			try RuntimeContext(identityID: "identity-test-a", threadID: "thread-test-a", runID: "run-test-1",
				channel: .cli, allowedResources: ["repository:src/app.swift", "monitoring:metrics.checkout", "runbook:deploy"])
		}
	}

	@Test
	func contentDigestsCoverRawUTF8BytesWithoutNormalization() throws {
		let composed = "é"
		let decomposed = "e\u{0301}"

		#expect(SourceResult.contentDigest(of: composed) != SourceResult.contentDigest(of: decomposed))
		#expect(SourceResult.contentDigest(of: "").count == 64)
		#expect(SourceResult.contentDigest(of: "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
		#expect(try Fixture.sourceResult(content: "").contentSHA256 == SourceResult.contentDigest(of: ""))
	}

	@Test
	func sourceResultsRejectMalformedFields() throws {
		#expect(throws: ContractError.self) { try Fixture.sourceResult(sourceID: "../escape") }
		#expect(throws: ContractError.self) { try Fixture.sourceResult(content: "null\0byte") }
		#expect(throws: ContractError.self) {
			try SourceResult(
				sourceFamily: .repository,
				sourceID: "repository:read:test",
				status: .ok,
				content: "text",
				contentSHA256: "not-a-digest"
			)
		}
		#expect(throws: ContractError.self) {
			try SourceResult(
				sourceFamily: .repository,
				sourceID: "repository:read:test",
				status: .ok,
				content: String(repeating: "a", count: SourceResult.maximumContentLength + 1),
				contentSHA256: SourceResult.contentDigest(of: "a")
			)
		}
		#expect(throws: ContractError.self) {
			try SourceResult(
				sourceFamily: .repository,
				sourceID: "repository:read:test",
				status: .ok,
				content: "text",
				contentSHA256: SourceResult.contentDigest(of: "text"),
				quarantinedSegments: ["not a marker"]
			)
		}
	}

	// "Non-empty" has to mean what it means in the contract of record, and Python's str.strip() removes
	// the information separators U+001C–U+001F that .whitespacesAndNewlines leaves in place. A field
	// holding nothing but a file separator was empty text there and valid text here.
	@Test
	func blankTextIsEverythingPythonsStripRemoves() throws {
		for blank in [" ", "\t", "\n", "\r\n", "\u{0b}", "\u{0c}", "\u{1c}", "\u{1d}", "\u{1e}", "\u{1f}", " \u{1c}\n"] {
			#expect(throws: ContractError.self) { try blank.validatedText("test text", maximum: 16) }
			#expect(throws: Never.self) { try blank.validatedText("test text", maximum: 16, allowEmpty: true) }
		}

		#expect(throws: Never.self) { try "\u{1c}visible".validatedText("test text", maximum: 16) }
		#expect(throws: ContractError.self) { try "text\0".validatedText("test text", maximum: 16) }
		#expect(throws: ContractError.self) { try "toolong".validatedText("test text", maximum: 3) }
	}

	@Test
	func resourceValidationFollowsTheFamilyPrefixedForm() throws {
		#expect(throws: Never.self) { try ["repository:src/a.swift"].validatedResources("test resources") }
		#expect(throws: ContractError.self) { try ["repository:"].validatedResources("test resources") }
		#expect(throws: ContractError.self) { try ["repository:../escape"].validatedResources("test resources") }
		#expect(throws: ContractError.self) { try ["repositories:a"].validatedResources("test resources") }
		#expect(throws: ContractError.self) {
			try ["repository:\(String(repeating: "a", count: 161))"].validatedResources("test resources")
		}
		#expect(throws: ContractError.self) {
			try (0...128).map { "repository:file-\($0)" }.validatedResources("test resources")
		}
	}

	@Test
	func contractErrorMessagesStayBoundedAndDoNotEchoValues() {
		let error = ContractError(String(repeating: "e", count: 400))

		#expect(error.description.count == 160)
		#expect((try? "\u{1b}[31m-secret".validatedIdentifier("source identifier")) == nil)
		do {
			_ = try "\u{1b}[31m-secret".validatedIdentifier("source identifier")
		} catch let error as ContractError {
			#expect(error.description == "source identifier must be a bounded opaque identifier")
		} catch {
			Issue.record("unexpected error type")
		}
	}

	@Test
	func evidenceCarriesNoSourceContent() throws {
		let context = try Fixture.context()
		let evidence = try Fixture.evidence(context)

		#expect(!"\(evidence)".contains("synthetic untrusted source text"))
		#expect(evidence.allowedResources.isEmpty)
		#expect(throws: ContractError.self) {
			try Evidence(
				evidenceID: "../escape",
				identityID: context.identityID,
				runID: context.runID,
				provenance: ProvenanceRef(Fixture.sourceResult()),
				status: .issued,
				trust: .untrustedData
			)
		}
	}
}
