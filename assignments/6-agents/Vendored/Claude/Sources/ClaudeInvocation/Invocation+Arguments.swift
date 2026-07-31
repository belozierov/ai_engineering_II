import Foundation
import ClaudeDomain

extension Invocation {

	public func arguments() throws -> [String] {
		var arguments: [String] = []

		if let model = configuration.model {
			arguments += ["--model", model.rawValue]
		}

		// Session ids render lowercase — CC's canonical form (transcript filenames, record
		// sessionId fields). Foundation's uuidString is uppercase, and CC adopts the resume
		// argument verbatim as the current session id: an uppercase resume of a real session
		// renders a different scratchpad path into system[2] and busts the prompt cache from
		// that breakpoint down (measured on the first real-parent shadow ride, 2026-07-06).
		switch origin {
		case .new(let sessionID):
			arguments += ["--session-id", sessionID.uuidString.lowercased()]

		case .resume(let sessionID):
			arguments += ["--resume", sessionID.uuidString.lowercased()]

		case .fork(let sessionID, let parent):
			arguments += ["--resume", parent.uuidString.lowercased()]
			arguments += ["--fork-session"]
			arguments += ["--session-id", sessionID.uuidString.lowercased()]
		}

		if let systemPrompt = configuration.systemPrompt {
			arguments += ["--system-prompt", systemPrompt]
		}
		if let appendSystemPrompt = configuration.appendSystemPrompt {
			arguments += ["--append-system-prompt", appendSystemPrompt]
		}
		if let effort = configuration.effort {
			arguments += ["--effort", effort.rawValue]
		}
		if let tools = configuration.tools {
			arguments += ["--tools", tools.map(\.rawValue).joined(separator: ",")]
		}
		if let maxTurns = configuration.maxTurns {
			arguments += ["--max-turns", String(maxTurns)]
		}
		if !configuration.agents.isEmpty {
			arguments += ["--agents", try agentsJSON()]
		}
		if configuration.permissions.isBypassingChecks {
			arguments += ["--dangerously-skip-permissions"]
		}
		if let mcpConfig {
			arguments += ["--mcp-config", try mcpConfig.makeJSON()]
		}

		arguments += ["--settings", try settings.makeJSON(over: settingsBase)]

		for directory in additionalDirectories {
			arguments += ["--add-dir", directory]
		}

		for feature in Claude.Feature.allCases where !configuration.features.contains(feature) {
			if case .arguments(let flags) = Self.disable(for: feature) {
				arguments += flags
			}
		}

		// Verbatim escape hatch for flags the typed surface doesn't model. Appended last:
		// claude takes a flag's final occurrence, so extras override anything generated above.
		arguments += extraArguments

		return arguments
	}

}
