extension Invocation {

	// Single source of truth for how a missing feature is switched off — claude exposes some
	// toggles as environment variables and others as argv flags; callers deal only in Claude.Feature.
	enum FeatureDisable {
		case environment(key: String, value: String)
		case arguments([String])
	}

	static func disable(for feature: Claude.Feature) -> FeatureDisable {
		switch feature {
		case .promptCaching: .environment(key: "DISABLE_PROMPT_CACHING", value: "1")
		case .autoCompaction: .environment(key: "DISABLE_AUTO_COMPACT", value: "1")
		case .projectInstructions: .environment(key: "CLAUDE_CODE_DISABLE_CLAUDE_MDS", value: "1")
		case .autoMemory: .environment(key: "CLAUDE_CODE_DISABLE_AUTO_MEMORY", value: "1")
		case .gitInstructions: .environment(key: "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS", value: "1")
		case .backgroundTasks: .environment(key: "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", value: "1")
		case .toolSearch: .environment(key: "ENABLE_TOOL_SEARCH", value: "0")
		case .telemetry: .environment(key: "DISABLE_TELEMETRY", value: "1")
		case .errorReporting: .environment(key: "DISABLE_ERROR_REPORTING", value: "1")
		case .autoUpdates: .environment(key: "DISABLE_AUTOUPDATER", value: "1")
		case .installationChecks: .environment(key: "DISABLE_INSTALLATION_CHECKS", value: "1")
		case .ideAutoConnect: .environment(key: "CLAUDE_CODE_AUTO_CONNECT_IDE", value: "0")
		case .nonessentialTraffic: .environment(key: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", value: "1")
		case .awaySummary: .environment(key: "CLAUDE_CODE_ENABLE_AWAY_SUMMARY", value: "0")
		case .slashCommands: .arguments(["--disable-slash-commands"])
		case .externalMCPServers: .arguments(["--strict-mcp-config"])
		case .chromeIntegration: .arguments(["--no-chrome"])
		case .inheritedSettings: .arguments(["--setting-sources", ""])
		}
	}

}
