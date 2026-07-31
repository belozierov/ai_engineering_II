import ClaudeDomain
import Foundation
import Testing

@testable import ClaudeInvocation

@Suite("Settings")
struct SettingsTests {

	// MARK: Hooks

	@Test
	func emptyHooksEncodeDisableAllHooks() throws {
		let settings = Settings(configuration: .sonnet)

		#expect(try settings.makeJSON() == #"{"disableAllHooks":true}"#)
	}

	@Test
	func hooksEncodeUnderEventKeys() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hooks = [Claude.Hook(event: .preToolUse, matcher: "Write", action: .command("echo hi"))]

		let json = try decode(Settings(configuration: configuration))

		let groups = try #require(json["hooks"] as? [String: [[String: Any]]])
		let entry = try #require(groups["PreToolUse"]?.first)
		let command = try #require((entry["hooks"] as? [[String: Any]])?.first)
		#expect(entry["matcher"] as? String == "Write")
		#expect(command["type"] as? String == "command")
		#expect(command["command"] as? String == "echo hi")
		#expect(json["disableAllHooks"] == nil)
	}

	@Test
	func injectedHooksEncodeAlongsideConfigured() throws {
		var settings = Settings(configuration: .sonnet)
		settings.hooks[.stop] = [Settings.Hook(matcher: "", command: "notify")]

		let json = try decode(settings)

		let groups = try #require(json["hooks"] as? [String: [[String: Any]]])
		#expect(groups["Stop"]?.first?["matcher"] as? String == "")
		#expect(json["disableAllHooks"] == nil)
	}

	// A user-facing session must not carry `disableAllHooks`: with no hooks to declare and the knob
	// off, the hook state disappears entirely so the user's own configured hooks keep running.
	@Test
	func emptyHooksOmitHookStateWhenNotDisablingUnlisted() throws {
		var settings = Settings(configuration: .sonnet)
		settings.disablesUnlistedHooks = false

		let json = try decode(settings)

		#expect(json["disableAllHooks"] == nil)
		#expect(json["hooks"] == nil)
	}

	@Test
	func nonEmptyHooksStillRenderRegardlessOfTheKnob() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hooks = [Claude.Hook(event: .preToolUse, matcher: "Write", action: .command("echo hi"))]
		var settings = Settings(configuration: configuration)
		settings.disablesUnlistedHooks = false

		let json = try decode(settings)

		#expect((json["hooks"] as? [String: Any])?.keys.contains("PreToolUse") == true)
		#expect(json["disableAllHooks"] == nil)
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
		configuration.permissions = Claude.Permissions(
			allow: [.tool(.write)],
			deny: [.agent(.plan), .agent(.generalPurpose)])

		let json = try decode(Settings(configuration: configuration))

		let permissions = try #require(json["permissions"] as? [String: [String]])
		#expect(permissions["allow"] == ["Write"])
		#expect(permissions["deny"] == ["Agent(Plan)", "Agent(general-purpose)"])
	}

	@Test
	func bypassDropsAllowKeepsDeny() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.permissions = Claude.Permissions(
			allow: [.tool(.write)],
			deny: [.agent(.plan)],
			isBypassingChecks: true)

		let json = try decode(Settings(configuration: configuration))

		let permissions = try #require(json["permissions"] as? [String: [String]])
		#expect(permissions["allow"] == [])
		#expect(permissions["deny"] == ["Agent(Plan)"])
	}

	@Test
	func hostedToolsAppendAllowRules() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hostedTools = [StubTool(name: "report_fact"), StubTool(name: "query_facts")]
		configuration.permissions = Claude.Permissions(allow: [.tool(.write)])

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
		configuration.hooks = [Claude.Hook(event: .postToolUse, matcher: "Write", action: .command("echo done"))]
		configuration.permissions = Claude.Permissions(allow: [.tool(.write)], deny: [.agent(.plan)])

		let json = try Settings(configuration: configuration).makeJSON()

		#expect(json == #"{"hooks":{"PostToolUse":[{"hooks":[{"command":"echo done","type":"command"}],"matcher":"Write"}]},"permissions":{"allow":["Write"],"deny":["Agent(Plan)"]}}"#)
	}

	// MARK: Base merge (launch replay)

	@Test
	func nilBaseRendersTheTypedSettingsAlone() throws {
		let settings = Settings(configuration: .sonnet)

		#expect(try settings.makeJSON(over: nil) == (try settings.makeJSON()))
	}

	// A replayed parent's fifo bridge must not reach this child: hook definitions are harness
	// plumbing (measured prefix-invisible), and a hooks-only base collapses to the typed render.
	@Test
	func hooksOnlyBaseIsDropped() throws {
		let settings = Settings(configuration: .sonnet)
		let base = #"{"hooks":{"Stop":[{"hooks":[{"command":"echo","type":"command"}],"matcher":""}]}}"#

		#expect(try settings.makeJSON(over: base) == (try settings.makeJSON()))
	}

	// The other hook-state shape this type renders: a hookless parent carries
	// `disableAllHooks: true`, and letting it survive next to the typed hooks would deafen the
	// fifo bridge the child is driven through (PTYSession waits on it until startupTimedOut).
	@Test
	func disableAllHooksBaseIsDroppedWithTheHookState() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hooks = [Claude.Hook(event: .preToolUse, matcher: "", action: .command("echo deny"))]
		let settings = Settings(configuration: configuration)

		#expect(try settings.makeJSON(over: #"{"disableAllHooks":true}"#) == (try settings.makeJSON()))

		let mixed = try settings.makeJSON(over: #"{"disableAllHooks":true,"statusLine":{"type":"command"}}"#)
		let object = try #require(try JSONSerialization.jsonObject(with: Data(mixed.utf8)) as? [String: Any])
		#expect(object["disableAllHooks"] == nil)
		#expect(object["statusLine"] != nil)
		#expect((object["hooks"] as? [String: Any])?.keys.contains("PreToolUse") == true)
	}

	@Test
	func foreignBaseKeysRideUnderTheTypedOnes() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.hooks = [Claude.Hook(event: .preToolUse, matcher: "", action: .command("echo deny"))]
		configuration.permissions = Claude.Permissions(deny: [.tool(.write)])
		let base = #"{"statusLine":{"type":"command"},"permissions":{"allow":["Read"]}}"#

		let merged = try Settings(configuration: configuration).makeJSON(over: base)
		let object = try #require(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])

		#expect(object["statusLine"] != nil)
		// Typed keys win whole on conflict — the base's permissions are not deep-merged in.
		#expect((object["permissions"] as? [String: Any])?["deny"] as? [String] == ["Write"])
		#expect((object["permissions"] as? [String: Any])?["allow"] as? [String] == [])
		#expect((object["hooks"] as? [String: Any])?.keys.contains("PreToolUse") == true)
	}

	@Test
	func malformedBaseFailsLoudly() {
		#expect(throws: Settings.Errors.malformedBase("not json")) {
			try Settings(configuration: .sonnet).makeJSON(over: "not json")
		}
	}

	// MARK: Rules

	@Test
	func ruleConstructorsMapToPatterns() {
		#expect(Claude.Permissions.Rule.tool(.read).rawValue == "Read")
		#expect(Claude.Permissions.Rule.agent(.generalPurpose).rawValue == "Agent(general-purpose)")
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
