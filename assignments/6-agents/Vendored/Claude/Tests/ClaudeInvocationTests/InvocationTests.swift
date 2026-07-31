import ClaudeDomain
import Foundation
import Testing

@testable import ClaudeInvocation

@Suite("Invocation")
struct InvocationTests {

	// MARK: Executable

	@Test
	func validatedExecutableReturnsExecutableFile() throws {
		let url = URL(filePath: NSTemporaryDirectory()).appending(path: "stub-claude-\(UUID().uuidString)")
		try Data("#!/bin/sh\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path())

		#expect(try Invocation.validatedExecutable(url) == url)
	}

	// Every desktop-bundled binary lives under "Application Support" — the percent-encoded
	// URL.path() form failed this check for a file that exists (measured, launch-replay probe).
	@Test
	func validatedExecutableAcceptsAPathWithSpaces() throws {
		let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "App Support \(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(path: "claude")
		try Data("#!/bin/sh\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))

		#expect(try Invocation.validatedExecutable(url) == url)
	}

	@Test
	func validatedExecutableThrowsForMissingFile() {
		let missing = URL(filePath: "/nonexistent/claude-\(UUID().uuidString)")

		#expect(throws: Invocation.Errors.self) {
			_ = try Invocation.validatedExecutable(missing)
		}
	}

	// MARK: Environment

	@Test
	func sanitizedEnvironmentStripsHostSessionMarkers() {
		let environment = [
			"CLAUDECODE": "1",
			"CLAUDE_CODE_ENTRYPOINT": "cli",
			"CLAUDE_CODE_SESSION_ID": "abc",
			"CLAUDE_EFFORT": "high",
			"AI_AGENT": "1",
			"PATH": "/usr/bin",
			"ANTHROPIC_API_KEY": "key",
			"TERM": "xterm-256color"
		]

		let sanitized = Invocation.sanitized(environment)

		#expect(sanitized == [
			"PATH": "/usr/bin",
			"ANTHROPIC_API_KEY": "key",
			"TERM": "xterm-256color"
		])
	}

	// MARK: Arguments

	@Test
	func modelMapsToFlag() throws {
		let arguments = try Invocation(configuration: .sonnet, origin: .new).arguments()

		#expect(value(of: "--model", in: arguments) == "sonnet")
	}

	// Unset model means claude's own default — forcing one would also namespace the
	// prompt cache away from sessions launched without --model.
	@Test
	func unsetModelOmitsFlag() throws {
		let arguments = try Invocation(configuration: Claude.SessionConfiguration(), origin: .new).arguments()

		#expect(!arguments.contains("--model"))
	}

	// Lowercase is CC's canonical id form: an uppercase --resume of a real session becomes the
	// current session id verbatim, renders a different scratchpad path into system[2] and busts
	// the prompt cache from that breakpoint down (measured 2026-07-06).
	@Test
	func newOriginEmitsLowercaseSessionID() throws {
		let id = UUID()

		let arguments = try Invocation(configuration: .sonnet, origin: .new(sessionID: id)).arguments()

		#expect(value(of: "--session-id", in: arguments) == id.uuidString.lowercased())
		#expect(!arguments.contains("--resume"))
		#expect(!arguments.contains("--fork-session"))
	}

	@Test
	func resumeOriginEmitsLowercaseResume() throws {
		let id = UUID()

		let arguments = try Invocation(configuration: .sonnet, origin: .resume(sessionID: id)).arguments()

		#expect(value(of: "--resume", in: arguments) == id.uuidString.lowercased())
		#expect(!arguments.contains("--session-id"))
		#expect(!arguments.contains("--fork-session"))
	}

	@Test
	func forkOriginEmitsResumeAndForkAndSessionID() throws {
		let parent = UUID()
		let child = UUID()

		let arguments = try Invocation(configuration: .sonnet, origin: .fork(sessionID: child, parent: parent)).arguments()

		#expect(value(of: "--resume", in: arguments) == parent.uuidString.lowercased())
		#expect(arguments.contains("--fork-session"))
		#expect(value(of: "--session-id", in: arguments) == child.uuidString.lowercased())
	}

	@Test
	func systemPromptMapsToFlag() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.systemPrompt = "You are concise."

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(value(of: "--system-prompt", in: arguments) == "You are concise.")
	}

	@Test
	func appendSystemPromptMapsToFlag() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.appendSystemPrompt = "Also stay factual."

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(value(of: "--append-system-prompt", in: arguments) == "Also stay factual.")
	}

	@Test
	func unsetAppendSystemPromptOmitsFlag() throws {
		let arguments = try Invocation(configuration: .sonnet, origin: .new).arguments()

		#expect(!arguments.contains("--append-system-prompt"))
	}

	@Test
	func effortMapsToFlag() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.effort = .high

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(value(of: "--effort", in: arguments) == "high")
	}

	@Test
	func defaultOmitsOptionalFlags() throws {
		let arguments = try Invocation(configuration: .sonnet, origin: .new).arguments()

		#expect(!arguments.contains("--system-prompt"))
		#expect(!arguments.contains("--effort"))
		#expect(!arguments.contains("--tools"))
		#expect(!arguments.contains("--agents"))
		#expect(!arguments.contains("--add-dir"))
		#expect(!arguments.contains("--dangerously-skip-permissions"))
		#expect(!arguments.contains("--mcp-config"))
	}

	// MARK: Tools

	@Test
	func emptyToolsEmitsEmptyValue() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.tools = []

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(value(of: "--tools", in: arguments) == "")
	}

	@Test
	func toolsJoinedWithComma() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.tools = [.read, .glob, .grep, .agent]

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(value(of: "--tools", in: arguments) == "Read,Glob,Grep,Agent")
	}

	// MARK: Permissions

	@Test
	func bypassEmitsDangerousFlag() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.permissions.isBypassingChecks = true

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(arguments.contains("--dangerously-skip-permissions"))
	}

	// MARK: MCP

	@Test
	func mcpConfigSerializedAsJSON() throws {
		let proxy = Claude.ToolProxyCommand(executable: URL(filePath: "/usr/local/bin/agent"), arguments: ["mcp-proxy"])
		let invocation = Invocation(configuration: .sonnet, origin: .new, mcpConfig: Invocation.MCPConfig(proxy: proxy, port: 54321))

		let json = try #require(value(of: "--mcp-config", in: try invocation.arguments()))

		#expect(json == #"{"mcpServers":{"app":{"args":["mcp-proxy"],"command":"/usr/local/bin/agent","env":{"CLAUDE_MCP_PORT":"54321"}}}}"#)
	}

	@Test
	func multiServerConfigSerializesEveryServerWithCustomEnvironment() throws {
		let config = Invocation.MCPConfig(servers: [
			Invocation.MCPConfig.Server(
				name: "alpha",
				executable: URL(filePath: "/opt/alpha"),
				arguments: ["--serve"],
				environment: ["ALPHA_TOKEN": "secret"]),
			Invocation.MCPConfig.Server(
				name: "beta",
				executable: URL(filePath: "/opt/beta"))
		])
		let invocation = Invocation(configuration: .sonnet, origin: .new, mcpConfig: config)

		let json = try #require(value(of: "--mcp-config", in: try invocation.arguments()))

		#expect(json == #"{"mcpServers":{"alpha":{"args":["--serve"],"command":"/opt/alpha","env":{"ALPHA_TOKEN":"secret"}},"beta":{"args":[],"command":"/opt/beta","env":{}}}}"#)
	}

	// URL.path() percent-encodes spaces to %20, which breaks the spawn for a command living
	// under a path with spaces ("Application Support/…"); the raw path must reach claude verbatim.
	@Test
	func executablePathWithSpaceKeepsLiteralSpace() throws {
		let config = Invocation.MCPConfig(servers: [
			Invocation.MCPConfig.Server(name: "spaced", executable: URL(filePath: "/opt/App Support/agent"))
		])

		let json = try config.makeJSON()

		#expect(json.contains(#""command":"/opt/App Support/agent""#))
		#expect(!json.contains("%20"))
	}

	@Test
	func proxyConvenienceMatchesEquivalentServerConfig() throws {
		let proxy = Claude.ToolProxyCommand(executable: URL(filePath: "/usr/local/bin/agent"), arguments: ["mcp-proxy"])

		let convenience = Invocation.MCPConfig(proxy: proxy, port: 54321)
		let explicit = Invocation.MCPConfig(servers: [
			Invocation.MCPConfig.Server(
				name: Claude.ToolProxyCommand.serverName,
				executable: proxy.executable,
				arguments: proxy.arguments,
				environment: [Claude.ToolProxyCommand.portEnvironmentVariable: "54321"])
		])

		#expect(try convenience.makeJSON() == explicit.makeJSON())
	}

	@Test
	func duplicateServerNamesThrow() throws {
		let config = Invocation.MCPConfig(servers: [
			Invocation.MCPConfig.Server(name: "twin", executable: URL(filePath: "/opt/one")),
			Invocation.MCPConfig.Server(name: "twin", executable: URL(filePath: "/opt/two"))
		])

		#expect(throws: Invocation.MCPConfig.Errors.duplicateServerName("twin")) {
			try config.makeJSON()
		}
	}

	// MARK: Agents

	@Test
	func agentsSerializedAsJSON() throws {
		let agent = Claude.AgentDefinition(
			name: "reviewer",
			description: "Code reviewer",
			prompt: "Review the change carefully.",
			model: .sonnet,
			effort: .medium,
			tools: [.read, .grep])
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.agents = [agent]

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		let json = try #require(value(of: "--agents", in: arguments))
		let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
		let reviewer = try #require(decoded?["reviewer"] as? [String: Any])

		#expect(reviewer["description"] as? String == "Code reviewer")
		#expect(reviewer["prompt"] as? String == "Review the change carefully.")
		#expect(reviewer["model"] as? String == "sonnet")
		#expect(reviewer["effort"] as? String == "medium")
		#expect(reviewer["tools"] as? [String] == ["Read", "Grep"])
	}

	// MARK: Settings & Isolation

	// The module adds nothing on its own — a bare configuration launches claude as claude behaves.
	@Test
	func defaultOmitsRestrictingFlags() throws {
		let arguments = try Invocation(configuration: .sonnet, origin: .new).arguments()

		#expect(value(of: "--settings", in: arguments) != nil)
		#expect(!arguments.contains("--setting-sources"))
		#expect(!arguments.contains("--disable-slash-commands"))
		#expect(!arguments.contains("--strict-mcp-config"))
		#expect(!arguments.contains("--no-chrome"))
	}

	@Test
	func disabledFeatureMapsToFlag() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.features.remove(.slashCommands)
		configuration.features.remove(.inheritedSettings)

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(arguments.contains("--disable-slash-commands"))
		#expect(value(of: "--setting-sources", in: arguments) == "")
		#expect(!arguments.contains("--strict-mcp-config"))
		#expect(!arguments.contains("--no-chrome"))
	}

	@Test
	func cagedFeaturesEmitAllIsolationFlags() throws {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.features = [.promptCaching]

		let arguments = try Invocation(configuration: configuration, origin: .new).arguments()

		#expect(arguments.contains("--disable-slash-commands"))
		#expect(arguments.contains("--strict-mcp-config"))
		#expect(arguments.contains("--no-chrome"))
		#expect(value(of: "--setting-sources", in: arguments) == "")
	}

	@Test
	func additionalDirectoriesEmitAddDir() throws {
		let invocation = Invocation(
			configuration: .sonnet,
			origin: .new,
			additionalDirectories: ["/tmp/before", "/tmp/current"])

		let arguments = try invocation.arguments()

		#expect(values(of: "--add-dir", in: arguments) == ["/tmp/before", "/tmp/current"])
	}

	// MARK: Golden

	@Test
	func canonicalArgumentsForRichConfiguration() throws {
		let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
		let configuration = Claude.SessionConfiguration(
			model: .sonnet,
			systemPrompt: "Review the diff.",
			effort: .high,
			tools: [.read, .grep],
			permissions: Claude.Permissions(allow: [.tool(.write)], deny: [.agent(.plan)]),
			agents: [Claude.AgentDefinition(name: "explorer", description: "Explores", prompt: "Explore.", model: .haiku)],
			hooks: [Claude.Hook(event: .postToolUse, matcher: "Write", action: .command("echo done"))])
		let invocation = Invocation(
			configuration: configuration,
			origin: .new(sessionID: id),
			additionalDirectories: ["/tmp/before"])

		#expect(try invocation.arguments() == [
			"--model", "sonnet",
			"--session-id", "11111111-2222-3333-4444-555555555555",
			"--system-prompt", "Review the diff.",
			"--effort", "high",
			"--tools", "Read,Grep",
			"--agents", #"{"explorer":{"description":"Explores","model":"haiku","prompt":"Explore."}}"#,
			"--settings", #"{"hooks":{"PostToolUse":[{"hooks":[{"command":"echo done","type":"command"}],"matcher":"Write"}]},"permissions":{"allow":["Write"],"deny":["Agent(Plan)"]}}"#,
			"--add-dir", "/tmp/before"
		])
	}

	// MARK: Extra Arguments

	// Last position is load-bearing: claude takes a flag's final occurrence, so extras
	// must be able to override any generated flag.
	@Test
	func extraArgumentsAppendedLast() throws {
		let invocation = Invocation(
			configuration: .sonnet,
			origin: .new,
			extraArguments: ["--model", "haiku", "--bare"])

		let arguments = try invocation.arguments()

		#expect(Array(arguments.suffix(3)) == ["--model", "haiku", "--bare"])
	}

	// MARK: Environment

	@Test
	func defaultFeaturesYieldEmptyEnvironment() {
		#expect(Invocation(configuration: .sonnet, origin: .new).environment.isEmpty)
	}

	@Test
	func disabledFeatureMapsToEnvVariable() {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.features.remove(.promptCaching)

		let environment = Invocation(configuration: configuration, origin: .new).environment

		#expect(environment["DISABLE_PROMPT_CACHING"] == "1")
		#expect(environment["DISABLE_TELEMETRY"] == nil)
	}

	@Test
	func emptyFeaturesDisableEverything() {
		var configuration = Claude.SessionConfiguration.sonnet
		configuration.features = []

		let environment = Invocation(configuration: configuration, origin: .new).environment

		#expect(environment == [
			"DISABLE_PROMPT_CACHING": "1",
			"DISABLE_AUTO_COMPACT": "1",
			"CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
			"CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
			"CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1",
			"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
			"ENABLE_TOOL_SEARCH": "0",
			"DISABLE_TELEMETRY": "1",
			"DISABLE_ERROR_REPORTING": "1",
			"DISABLE_AUTOUPDATER": "1",
			"DISABLE_INSTALLATION_CHECKS": "1",
			"CLAUDE_CODE_AUTO_CONNECT_IDE": "0",
			"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
			"CLAUDE_CODE_ENABLE_AWAY_SUMMARY": "0"
		])
	}

}

// MARK: Helpers

extension Claude.SessionConfiguration {

	static var sonnet: Self { Self(model: .sonnet) }

}

private func value(of flag: String, in arguments: [String]) -> String? {
	values(of: flag, in: arguments).first
}

private func values(of flag: String, in arguments: [String]) -> [String] {
	arguments.indices.compactMap { index in
		guard arguments[index] == flag, index + 1 < arguments.count else { return nil }
		return arguments[index + 1]
	}
}
