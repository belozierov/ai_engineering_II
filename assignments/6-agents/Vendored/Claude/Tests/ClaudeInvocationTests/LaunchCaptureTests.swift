import Foundation
import Testing
@testable import ClaudeInvocation

@Suite("EnvironmentPolicy")
struct EnvironmentPolicyTests {

	@Test
	func applyRemovesAndAdds() {
		let policy = EnvironmentPolicy(removedKeys: ["ANTHROPIC_API_KEY"], addedValues: ["AUTOSKILL_OBSERVER": "1"])

		let result = policy.apply(to: ["ANTHROPIC_API_KEY": "secret", "PATH": "/usr/bin"])

		#expect(result == ["PATH": "/usr/bin", "AUTOSKILL_OBSERVER": "1"])
	}

	@Test
	func addedValuesOverrideExisting() {
		let policy = EnvironmentPolicy(addedValues: ["ANTHROPIC_MODEL": "opus"])

		let result = policy.apply(to: ["ANTHROPIC_MODEL": "sonnet"])

		#expect(result["ANTHROPIC_MODEL"] == "opus")
	}

	@Test
	func prefixRelevantKeepsModelAndFeatureToggles() {
		let environment = [
			"ANTHROPIC_MODEL": "opus",
			"DISABLE_PROMPT_CACHING": "1",
			"ANTHROPIC_API_KEY": "secret",
			"PATH": "/usr/bin",
			"CLAUDE_CODE_OAUTH_TOKEN": "secret"
		]

		let relevant = EnvironmentPolicy.prefixRelevant(from: environment)

		#expect(relevant == ["ANTHROPIC_MODEL": "opus", "DISABLE_PROMPT_CACHING": "1"])
	}

}

@Suite("ProcessLaunchReader")
struct ProcessLaunchReaderTests {

	@Test
	func parsesArgvAndEnvironment() throws {
		let launch = try ProcessLaunchReader.parse(buffer(
			argc: 3,
			executablePath: "/usr/local/bin/claude",
			strings: ["claude", "--model", "opus name", "ANTHROPIC_MODEL=opus", "PATH=/usr/bin", "ptr_munge"]))

		#expect(launch.executablePath == "/usr/local/bin/claude")
		#expect(launch.arguments == ["claude", "--model", "opus name"])
		#expect(launch.environment == ["ANTHROPIC_MODEL": "opus", "PATH": "/usr/bin"])
	}

	@Test
	func environmentStopsAtAppleBlock() throws {
		let launch = try ProcessLaunchReader.parse(buffer(
			argc: 1,
			executablePath: "/bin/claude",
			strings: ["claude", "A=1", "apple_no_equals", "B=2"]))

		#expect(launch.environment == ["A": "1"])
	}

	@Test
	func truncatedBufferThrows() {
		#expect(throws: ProcessLaunchReader.Errors.self) {
			try ProcessLaunchReader.parse(Data([1, 0]))
		}
	}

	@Test
	func readsOwnProcessFaithfully() throws {
		let launch = try ProcessLaunchReader.read(processID: ProcessInfo.processInfo.processIdentifier)

		#expect(launch.arguments.first?.contains("xctest") == true || launch.arguments.first?.contains("swiftpm") == true
			|| launch.arguments.first?.isEmpty == false)
		#expect(launch.environment["PATH"] != nil)
	}

	private func buffer(argc: Int32, executablePath: String, strings: [String]) -> Data {
		var data = Data()
		withUnsafeBytes(of: argc.littleEndian) { data.append(contentsOf: $0) }
		data.append(contentsOf: executablePath.utf8)
		data.append(contentsOf: [0, 0, 0])
		for string in strings {
			data.append(contentsOf: string.utf8)
			data.append(0)
		}
		return data
	}

}
