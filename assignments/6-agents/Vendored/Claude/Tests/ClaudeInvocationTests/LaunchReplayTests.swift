import Foundation
import Testing
import ClaudeDomain

@testable import ClaudeInvocation

@Suite("Launch replay transform")
struct LaunchReplayTests {

	// The real claude-desktop launch from the probe (2026-07-07) — the fixture the design
	// doc names as the transform's acceptance input.
	private static let desktopLaunch = ProcessLaunch(
		executablePath: "/Users/u/Library/Application Support/Claude/claude-code/2.1.197/claude.app/Contents/MacOS/claude",
		arguments: [
			"claude",
			"--output-format", "stream-json",
			"--verbose",
			"--input-format", "stream-json",
			"--effort", "high",
			"--model", "claude-opus-4-8",
			"--permission-prompt-tool", "stdio",
			"--resume", "ff60f16e-b810-4462-8ad9-71fb3fef4455",
			"--allowedTools", "mcp__computer-use,mcp__ccd_session__spawn_task",
			"--mcp-config", #"{"mcpServers":{"LSPMCP":{"type":"stdio","command":"/Users/u/.claude/tools/LSPMCP"}}}"#,
			"--setting-sources=user,project,local",
			"--permission-mode", "default",
			"--allow-dangerously-skip-permissions",
			"--include-partial-messages",
			"--plugin-dir", "/Users/u/.claude/plugins/cache/lobyco-skills/app-tools/1.1.0",
			"--plugin-dir", "/Users/u/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/uuid",
			"--replay-user-messages",
			"--settings", "{}",
		],
		environment: [
			"HOME": "/Users/u",
			"ENABLE_TOOL_SEARCH": "false",
			"ANTHROPIC_API_KEY": "key",
			"CLAUDE_CODE_OAUTH_TOKEN": "token",
			"CLAUDE_CODE_OAUTH_SCOPES": "scopes",
			"CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH": "true",
			"CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "true",
		])

	@Test
	func desktopLaunchStripsTransportOriginAndSettingsKeepingTheRestVerbatim() {
		let replay = LaunchReplay.make(from: Self.desktopLaunch)

		#expect(replay.executable == URL(filePath: Self.desktopLaunch.executablePath))
		#expect(replay.arguments == [
			"--effort", "high",
			"--model", "claude-opus-4-8",
			"--allowedTools", "mcp__computer-use,mcp__ccd_session__spawn_task",
			"--mcp-config", #"{"mcpServers":{"LSPMCP":{"type":"stdio","command":"/Users/u/.claude/tools/LSPMCP"}}}"#,
			"--setting-sources=user,project,local",
			"--permission-mode", "default",
			"--allow-dangerously-skip-permissions",
			"--plugin-dir", "/Users/u/.claude/plugins/cache/lobyco-skills/app-tools/1.1.0",
			"--plugin-dir", "/Users/u/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/uuid",
		])
		#expect(replay.settings == "{}")
	}

	@Test
	func credentialBundleNeverTravels() {
		let replay = LaunchReplay.make(from: Self.desktopLaunch)

		#expect(replay.environment == ["HOME": "/Users/u", "ENABLE_TOOL_SEARCH": "false"])
	}

	@Test
	func flaglessLaunchProducesAnEmptyTail() {
		let replay = LaunchReplay.make(from: ProcessLaunch(
			executablePath: "/usr/local/bin/claude",
			arguments: ["claude"],
			environment: [:]))

		#expect(replay.arguments.isEmpty)
		#expect(replay.settings == nil)
	}

	// Both flag shapes must strip their value: `--flag value` and `--flag=value`.
	@Test
	func equalsShapedDenylistFlagsStripInline() {
		let replay = LaunchReplay.make(from: ProcessLaunch(
			executablePath: "/usr/local/bin/claude",
			arguments: ["claude", "--resume=abc", "--settings={\"a\":1}", "--output-format=stream-json", "--model", "opus"],
			environment: [:]))

		#expect(replay.arguments == ["--model", "opus"])
		#expect(replay.settings == #"{"a":1}"#)
	}

	// An override is applied into the tail: the tail is the invocation's final occurrence, so
	// anywhere earlier the launch's own flag would win.
	@Test
	func explicitOverridesReplaceTheLaunchFlagsAtTheTailEnd() {
		let replay = LaunchReplay.make(
			from: ProcessLaunch(
				executablePath: "/usr/local/bin/claude",
				arguments: ["claude", "--model", "claude-opus-4-8", "--effort=high", "--plugin-dir", "/p"],
				environment: [:]),
			model: .sonnet,
			effort: .low)

		#expect(replay.arguments == ["--plugin-dir", "/p", "--model", "sonnet", "--effort", "low"])
	}

	@Test
	func overrideAppendsWhenTheLaunchCarriedNoFlag() {
		let replay = LaunchReplay.make(
			from: ProcessLaunch(executablePath: "/usr/local/bin/claude", arguments: ["claude"], environment: [:]),
			model: .sonnet)

		#expect(replay.arguments == ["--model", "sonnet"])
	}

}
