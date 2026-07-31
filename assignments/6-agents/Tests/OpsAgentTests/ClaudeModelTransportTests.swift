import ClaudeDomain
import Foundation
import Testing

@testable import OpsAgent

// The hermetic session recipe is the whole value of the live adapter, and it is verified without
// spawning claude: the configuration is a value, so every invariant the spike established is an
// assertion over that value.
@Suite("Claude model transport")
struct ClaudeModelTransportTests {

	@Test
	func builtInToolsAreRemovedRatherThanLeftUnset() {
		let configuration = ClaudeModelTransport.configuration(for: TransportFixture.setup())

		#expect(configuration.tools != nil)
		#expect(configuration.tools?.isEmpty == true)
	}

	@Test
	func everySendIsCutOffAfterOneTurn() {
		#expect(ClaudeModelTransport.configuration(for: TransportFixture.setup()).maxTurns == 1)
	}

	@Test
	func featuresAreTheDefaultsMinusTheSevenThatBreakHermeticity() {
		let configuration = ClaudeModelTransport.configuration(for: TransportFixture.setup())
		let removed: Claude.Features = [
			.toolSearch,
			.projectInstructions,
			.autoMemory,
			.inheritedSettings,
			.externalMCPServers,
			.autoCompaction,
			.slashCommands
		]

		#expect(removed.count == 7)
		#expect(configuration.features == Claude.Features.default.subtracting(removed))
		#expect(configuration.features.isDisjoint(with: removed))
	}

	@Test
	func eachHostedToolGetsItsOwnAllowRuleAndChecksAreBypassed() {
		let log = TransportCallLog()
		let tools: [any Claude.HostedTool] = [
			TransportIncidentTool(incidentCode: "code", callLog: log),
			TransportOverlapTool(log: TransportOverlapLog())
		]
		let configuration = ClaudeModelTransport.configuration(for: TransportFixture.setup(hosting: tools))

		#expect(configuration.permissions.allow == [
			.hostedTool(named: "fetch_incident_code"),
			.hostedTool(named: "record_overlap")
		])
		#expect(configuration.permissions.deny.isEmpty)
		#expect(configuration.permissions.isBypassingChecks)
		#expect(configuration.hostedTools.map(\.name) == ["fetch_incident_code", "record_overlap"])
	}

	@Test
	func theSystemPromptReplacesRatherThanAppends() {
		let setup = ModelSessionSetup(model: .sonnet, systemPrompt: "Ops copilot.", requestTimeout: .seconds(42))
		let configuration = ClaudeModelTransport.configuration(for: setup)

		#expect(configuration.systemPrompt == "Ops copilot.")
		#expect(configuration.appendSystemPrompt == nil)
	}

	@Test
	func theModelAndTimeoutComeFromTheSetup() {
		let setup = ModelSessionSetup(model: .sonnet, systemPrompt: "Ops copilot.", requestTimeout: .seconds(42))
		let configuration = ClaudeModelTransport.configuration(for: setup)

		#expect(configuration.model == .sonnet)
		#expect(configuration.requestTimeout == .seconds(42))
	}

	// claude resolves the cwd before deriving its ~/.claude/projects folder name, so the transport
	// must hand the factory the resolved path — an unresolved one loses every transcript.
	@Test(.enabled(if: TransportFixture.isClaudeExecutableAvailable))
	func theWorkingDirectoryIsSymlinkResolved() throws {
		try TransportFixture.withSymlinkedDirectory { link, target in
			let proxy = Claude.ToolProxyCommand(executable: URL(filePath: "/usr/bin/true"))
			let transport = try ClaudeModelTransport(workingDirectory: link, toolProxy: proxy)

			#expect(transport.workingDirectory == target.resolvingSymlinksInPath())
			#expect(transport.workingDirectory != link)
		}
	}

}
