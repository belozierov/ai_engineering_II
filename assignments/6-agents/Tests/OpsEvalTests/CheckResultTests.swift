import Testing

import OpsCore

@testable import OpsEval

@Suite("Bounded check results")
struct CheckResultTests {

	@Test
	func skipMustNameTheStudentTodoItStandsFor() throws {
		let skipped = try CheckResult.skip(
			"todo.U4-1-agent-composition",
			message: "student TODO is not implemented",
			todoID: "U4-1-agent-composition",
			capabilities: [.planning]
		)

		#expect(skipped.state == .skip)
		#expect(skipped.todoID == "U4-1-agent-composition")
		#expect(throws: ContractError.self) {
			try CheckResult(name: "todo.U4-1-agent-composition", state: .skip, message: "not implemented")
		}
	}

	@Test
	func onlySkipMayCarryAStudentTodoIdentifier() {
		for state in ResultState.allCases where state != .skip {
			#expect(throws: ContractError.self) {
				try CheckResult(
					name: "todo.U4-2-bounded-source-tools",
					state: state,
					message: "observed",
					todoID: "U4-2-bounded-source-tools"
				)
			}
		}
	}

	@Test
	func studentTodoIdentifiersMustMatchTheDeclaredExerciseShape() {
		let invalid = ["U4-0-agent-composition", "U4-7-agent-composition", "U5-1-agent-composition",
			"U4-1-", "U4-1-Agent-Composition", "U4-1-\(String(repeating: "a", count: 81))", "U4-1"]

		for todoID in invalid {
			#expect(throws: ContractError.self) {
				try CheckResult.skip("todo.U4-1-agent-composition", message: "not implemented", todoID: todoID)
			}
		}
		#expect(throws: Never.self) {
			try CheckResult.skip(
				"todo.U4-6-evidence-action-policy",
				message: "not implemented",
				todoID: "U4-6-\(String(repeating: "a", count: 80))"
			)
		}
	}

	@Test
	func resultNamesMustBeBoundedIdentifiers() {
		for name in ["", ".leading-dot", "has space", "has/slash", String(repeating: "a", count: 129)] {
			#expect(throws: ContractError.self) { try CheckResult.pass(name, message: "observed") }
		}
		#expect(throws: Never.self) { try CheckResult.pass(String(repeating: "a", count: 128), message: "observed") }
	}

	@Test
	func capabilitiesMustBeUniqueAndKeepTheirCitedOrder() throws {
		let result = try CheckResult.pass("scenario.replanning", message: "observed", capabilities: [.replanning, .planning])

		#expect(result.capabilities == [.replanning, .planning])
		#expect(throws: ContractError.self) {
			try CheckResult.pass("scenario.replanning", message: "observed", capabilities: [.planning, .planning])
		}
	}

	// MARK: Messages

	@Test
	func messagesLoseControlsAndAreBoundedToThreeHundredCharacters() throws {
		let result = try CheckResult.fail("safe.output", message: "line one\n<script>\u{1b}[31m" + String(repeating: "x", count: 1_000))

		#expect(!result.message.contains("\n"))
		#expect(!result.message.contains("\u{1b}"))
		#expect(result.message.unicodeScalars.count == CheckResult.maximumMessageLength)
		#expect(result.message.hasPrefix("line one <script> [31mxxx"))
	}

	@Test
	func messagesCollapseRunsOfWhitespaceAndTrimTheEdges() throws {
		let result = try CheckResult.pass("safe.spacing", message: "  two\t\t words \u{a0}here \n ")

		#expect(result.message == "two words here")
	}

	@Test
	func messagesWithNothingVisibleFallBackToABoundedSentence() throws {
		for message in ["", "   ", "\u{1b}\u{7}\n\t"] {
			#expect(try CheckResult.pass("safe.empty", message: message).message == CheckResult.unavailableMessage)
		}
	}

	// Normalizing to NFC keeps a decomposed and a precomposed spelling of the same message from reading as
	// two different rows.
	@Test
	func messagesAreNormalizedToPrecomposedForm() throws {
		let decomposed = try CheckResult.pass("safe.normalization", message: "cafe\u{301} latte")

		#expect(decomposed.message == "café latte")
	}

	// MARK: Serialization

	@Test
	func rowsSerializeTheirPublicShapeAndOmitAnAbsentTodoIdentifier() throws {
		var report = try Fixture.report(core: [
			CheckResult.pass("component.evidence-policy", message: "observed", capabilities: [.planning])
		])
		#expect(try report.json().contains(
			#"{"capabilities":["planning"],"message":"observed","name":"component.evidence-policy","state":"PASS"}"#
		))

		report = try Fixture.report(core: [
			CheckResult.skip("todo.U4-5-guided-compaction", message: "not implemented", todoID: "U4-5-guided-compaction")
		])
		#expect(try report.json().contains(#"""
			{"capabilities":[],"message":"not implemented","name":"todo.U4-5-guided-compaction",\#
			"state":"SKIP","todo_id":"U4-5-guided-compaction"}
			"""#))
	}
}
