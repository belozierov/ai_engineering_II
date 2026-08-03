import Foundation
import Testing

@testable import OpsCore

@Suite("Opaque scope derivation")
struct ScopeSecretTests {

	@Test
	func sameInputsDeriveTheSameScope() throws {
		let secret = try Fixture.secret()

		let first = secret.opaqueScope(.evidence, identifiers: ["identity-a", "thread-a", "run-a"])
		let second = secret.opaqueScope(.evidence, identifiers: ["identity-a", "thread-a", "run-a"])

		#expect(first == second)
		#expect(first.hasPrefix("evscope-"))
		#expect(first.dropFirst("evscope-".count).count == 64)
	}

	@Test
	func anySingleIdentifierChangeChangesTheScope() throws {
		let secret = try Fixture.secret()
		let base = secret.opaqueScope(.evidence, identifiers: ["identity-a", "thread-a", "run-a"])

		#expect(secret.opaqueScope(.evidence, identifiers: ["identity-b", "thread-a", "run-a"]) != base)
		#expect(secret.opaqueScope(.evidence, identifiers: ["identity-a", "thread-b", "run-a"]) != base)
		#expect(secret.opaqueScope(.evidence, identifiers: ["identity-a", "thread-a", "run-b"]) != base)
		#expect(secret.opaqueScope(.eventView, identifiers: ["identity-a", "thread-a", "run-a"]) != base)
	}

	@Test
	func lengthFramingKeepsIdentifierBoundariesUnambiguous() throws {
		let secret = try Fixture.secret()

		#expect(secret.opaqueDigest(.evidence, identifiers: ["ab", "c"]) != secret.opaqueDigest(.evidence, identifiers: ["a", "bc"]))
		#expect(secret.opaqueDigest(.evidence, identifiers: ["a", ""]) != secret.opaqueDigest(.evidence, identifiers: ["a"]))
	}

	@Test
	func differentSecretsNeverShareAScope() throws {
		let other = try ScopeSecret(Data("clearly-fake-test-scope-key-0002".utf8))

		#expect(try Fixture.secret().opaqueDigest(.evidence, identifiers: ["a"]) != other.opaqueDigest(.evidence, identifiers: ["a"]))
	}

	@Test
	func secretsMustBeBoundedBytes() {
		#expect(throws: ContractError.self) { try ScopeSecret(Data(repeating: 0x61, count: 31)) }
		#expect(throws: ContractError.self) { try ScopeSecret(Data()) }
		#expect(throws: ContractError.self) { try ScopeSecret(Data(repeating: 0x61, count: 1_025)) }
		#expect(throws: Never.self) { try ScopeSecret(Data(repeating: 0x61, count: 1_024)) }
	}

	@Test
	func domainsAndPrefixesMustBeBoundedConstants() throws {
		#expect(throws: Never.self) { try ScopeSecret.Domain(name: "ops-copilot:test:v1", prefix: "test-1") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: "", prefix: "test") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: String(repeating: "d", count: 65), prefix: "test") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: "домен", prefix: "test") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: "ops:test", prefix: "") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: "ops:test", prefix: "-") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: "ops:test", prefix: "under_score") }
		#expect(throws: ContractError.self) { try ScopeSecret.Domain(name: "ops:test", prefix: "seventeen-chars-x") }
	}

	// Locks the framing against the Python contract: the constant below was produced by
	// ops_scaffold.scoping.derive_opaque_scope with the same secret, domain and identifiers.
	@Test
	func derivationMatchesThePythonScopeContract() throws {
		let scope = try Fixture.secret().opaqueScope(.evidence, identifiers: ["identity-test-a", "thread-test-a", "run-test-1"])

		#expect(scope == "evscope-9c1f73b00f2c2c8c3b93b16a71443c0a212acbdc1ff5d677699b636bf057afe0")
	}

	// The constants are derived through the validating initializer, so they are held to the same rules a
	// caller's own domain is: this asserts that, rather than trusting four literals to stay well-formed.
	@Test
	func coreDomainsUseTheDocumentedNamesAndPrefixes() {
		for domain in [ScopeSecret.Domain.evidence, .eventView, .planSnapshot, .planRun] {
			#expect(throws: Never.self) { try ScopeSecret.Domain(name: domain.name, prefix: domain.prefix) }
		}

		#expect(ScopeSecret.Domain.evidence.name == "ops-copilot:evidence:v1")
		#expect(ScopeSecret.Domain.evidence.prefix == "evscope")
		#expect(ScopeSecret.Domain.eventView.name == "ops-copilot:event-view:v1")
		#expect(ScopeSecret.Domain.eventView.prefix == "eventview")
		#expect(ScopeSecret.Domain.planSnapshot.name == "ops-copilot:plan-snapshot:v1")
		#expect(ScopeSecret.Domain.planSnapshot.prefix == "plan")
		#expect(ScopeSecret.Domain.planRun.name == "ops-copilot:plan-run:v1")
		#expect(ScopeSecret.Domain.planRun.prefix == "planrun")
	}
}
