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
		// The excerpt side channel is the one flag whose absence is a contract of its own: no path, no
		// recorder, and a run byte-identical to the one an operator gets.
		#expect(options.excerptsFile == nil)
	}

	@Test
	func everyFlagIsRead() throws {
		let options = try CLIOptions.parse(
			[
				"--thread", "incident-two",
				"--json",
				"--workspace", "/tmp/elsewhere",
				"--data", "fixtures",
				"--excerpts-file", "excerpts.jsonl"
			],
			directory: Self.directory
		)

		#expect(options.thread == "incident-two")
		#expect(options.isJSON)
		#expect(options.workspace.path(percentEncoded: false) == "/tmp/elsewhere/")
		#expect(options.data.path(percentEncoded: false) == "/tmp/ops-cli-flags/fixtures/")
		// Resolved against the working directory like the other two paths, and as a file rather than a
		// directory — a trailing slash here would name something nothing can be appended to.
		#expect(options.excerptsFile?.path(percentEncoded: false) == "/tmp/ops-cli-flags/excerpts.jsonl")
	}

	@Test
	func theUsageNamesTheExcerptsFileAsEvaluationOnly() {
		#expect(CLIOptions.usage.contains("--excerpts-file <path>"))
		#expect(CLIOptions.usage.contains("(eval only)"))
	}

	@Test(arguments: [
		["--unknown"],
		["incident-two"],
		["--thread"],
		["--thread", "--json"],
		["--workspace"],
		["--data", ""],
		["--excerpts-file"],
		["--excerpts-file", "--json"],
		["--excerpts-file", ""]
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
