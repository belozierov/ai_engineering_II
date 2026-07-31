import Foundation
import OpsCLI
import Testing

@Suite("Console flags")
struct CLIOptionsTests {

	static let directory = URL(filePath: "/tmp/ops-cli-flags", directoryHint: .isDirectory)

	@Test
	func theDefaultsAreTheAssignmentsThreadAndTheWorkingDirectorysWorkspaceAndData() throws {
		let options = try CLIOptions.parse([], directory: Self.directory)

		#expect(options.thread == "incident-main")
		#expect(options.isJSON == false)
		#expect(options.workspace.path(percentEncoded: false) == "/tmp/ops-cli-flags/workspace/")
		#expect(options.data.path(percentEncoded: false) == "/tmp/ops-cli-flags/data/")
	}

	@Test
	func everyFlagIsRead() throws {
		let options = try CLIOptions.parse(
			["--thread", "incident-two", "--json", "--workspace", "/tmp/elsewhere", "--data", "fixtures"],
			directory: Self.directory
		)

		#expect(options.thread == "incident-two")
		#expect(options.isJSON)
		#expect(options.workspace.path(percentEncoded: false) == "/tmp/elsewhere/")
		#expect(options.data.path(percentEncoded: false) == "/tmp/ops-cli-flags/fixtures/")
	}

	@Test(arguments: [
		["--unknown"],
		["incident-two"],
		["--thread"],
		["--thread", "--json"],
		["--workspace"],
		["--data", ""]
	])
	func anythingElseIsAUsageFailure(arguments: [String]) {
		#expect(throws: CLIUsageError.self) { try CLIOptions.parse(arguments, directory: Self.directory) }
	}

	// A thread identifier the contract refuses is not a usage failure — the reference CLI answers it with a
	// code of its own — so parsing carries it through and the startup path decides.
	@Test
	func anUnusableThreadIdentifierSurvivesParsing() throws {
		#expect(try CLIOptions.parse(["--thread", "../escape"], directory: Self.directory).thread == "../escape")
	}
}
