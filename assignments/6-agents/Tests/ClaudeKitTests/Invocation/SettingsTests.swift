import Foundation
import Testing

@testable import ClaudeKit

@Suite("Settings")
struct SettingsTests {

	// MARK: Hooks

	@Test
	func everySessionSilencesInheritedHooks() throws {
		let settings = Settings(configuration: .sonnet)

		#expect(try settings.makeJSON() == #"{"disableAllHooks":true}"#)
	}

	// MARK: Permissions

	@Test
	func emptyPermissionsOmitted() throws {
		let json = try decode(Settings(configuration: .sonnet))

		#expect(json["permissions"] == nil)
	}

	@Test
	func permissionsEncodeAllowAndDeny() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.permissions = Claude.Permissions(allow: ["Write"], deny: ["Bash(rm:*)", "Read(./secrets/**)"])

		let json = try decode(Settings(configuration: configuration))

		let permissions = try #require(json["permissions"] as? [String: [String]])
		#expect(permissions["allow"] == ["Write"])
		#expect(permissions["deny"] == ["Bash(rm:*)", "Read(./secrets/**)"])
	}

	@Test
	func bypassDropsAllowKeepsDeny() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.permissions = Claude.Permissions(allow: ["Write"], deny: ["Bash(rm:*)"], isBypassingChecks: true)

		let json = try decode(Settings(configuration: configuration))

		let permissions = try #require(json["permissions"] as? [String: [String]])
		#expect(permissions["allow"] == [])
		#expect(permissions["deny"] == ["Bash(rm:*)"])
	}

	@Test
	func hostedToolsAppendAllowRules() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hostedTools = [StubTool(name: "report_fact"), StubTool(name: "query_facts")]
		configuration.permissions = Claude.Permissions(allow: ["Write"])

		let json = try decode(Settings(configuration: configuration))

		let permissions = try #require(json["permissions"] as? [String: [String]])
		#expect(permissions["allow"] == ["Write", "mcp__app__report_fact", "mcp__app__query_facts"])
	}

	@Test
	func hostedToolRulesDroppedUnderBypass() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hostedTools = [StubTool(name: "report_fact")]
		configuration.permissions = Claude.Permissions(isBypassingChecks: true)

		let json = try decode(Settings(configuration: configuration))

		#expect(json["permissions"] == nil)
	}

	// MARK: Golden

	@Test
	func richSettingsEncodeCanonically() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.permissions = Claude.Permissions(allow: ["Write"], deny: ["Bash(rm:*)"])

		let json = try Settings(configuration: configuration).makeJSON()

		#expect(json == #"{"disableAllHooks":true,"permissions":{"allow":["Write"],"deny":["Bash(rm:*)"]}}"#)
	}

	// MARK: Rules

	@Test
	func ruleConstructorsMapToPatterns() {
		#expect(Claude.Permissions.Rule.hostedTool(named: "report_fact").rawValue == "mcp__app__report_fact")
		#expect(("Bash(git log:*)" as Claude.Permissions.Rule).rawValue == "Bash(git log:*)")
	}

	// MARK: Helpers

	private func decode(_ settings: Settings) throws -> [String: Any] {
		let json = try settings.makeJSON()
		let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
		return try #require(object as? [String: Any])
	}

}
