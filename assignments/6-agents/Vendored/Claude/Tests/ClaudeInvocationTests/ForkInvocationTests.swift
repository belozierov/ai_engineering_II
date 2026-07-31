import Foundation
import Testing
@testable import ClaudeInvocation

@Suite("ForkInvocation")
struct ForkInvocationTests {

	@Test
	func plainLaunchProducesForkPlumbingOnly() {
		let fork = ForkInvocation(parentSessionID: "abc", launch: launch(arguments: ["claude"]))

		#expect(fork.arguments == ["--print", "--output-format", "json", "--resume", "abc", "--fork-session"])
	}

	@Test
	func maxTurnsAppendsGuard() {
		let fork = ForkInvocation(parentSessionID: "abc", launch: launch(arguments: ["claude"]), maxTurns: 15)

		#expect(fork.arguments.suffix(2) == ["--max-turns", "15"])
	}

	@Test
	func prefixAffectingFlagsAreCarriedWithValues() {
		let fork = ForkInvocation(
			parentSessionID: "abc",
			launch: launch(arguments: ["claude", "--model", "opus", "--effort", "high"]))

		#expect(Array(fork.arguments.prefix(4)) == ["--model", "opus", "--effort", "high"])
	}

	@Test
	func transportFlagsAreDropped() {
		let fork = ForkInvocation(
			parentSessionID: "abc",
			launch: launch(arguments: ["claude", "--verbose", "--output-format", "stream-json", "--model", "opus"]))

		#expect(fork.prefixAffectingArguments == ["--model", "opus"])
	}

	@Test
	func repeatedFlagsAreAllCarried() {
		let fork = ForkInvocation(
			parentSessionID: "abc",
			launch: launch(arguments: ["claude", "--plugin-dir", "/a", "--plugin-dir", "/b c"]))

		#expect(fork.prefixAffectingArguments == ["--plugin-dir", "/a", "--plugin-dir", "/b c"])
	}

	@Test
	func equalsSignFormIsCarriedWhole() {
		let fork = ForkInvocation(parentSessionID: "abc", launch: launch(arguments: ["claude", "--model=opus"]))

		#expect(fork.prefixAffectingArguments == ["--model=opus"])
	}

	@Test
	func executableArgumentIsNeverAFlag() {
		let fork = ForkInvocation(parentSessionID: "abc", launch: launch(arguments: ["--model"]))

		#expect(fork.prefixAffectingArguments.isEmpty)
	}

	private func launch(arguments: [String]) -> ProcessLaunch {
		ProcessLaunch(executablePath: "/usr/local/bin/claude", arguments: arguments, environment: [:])
	}

}
