// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation

extension Invocation {

	// The child session is independent, never nested: a hosting Claude Code session's markers
	// must not leak in — claude that inherits them treats itself as a child session and stops
	// persisting the interactive transcript, which starves transcript-based consumers like the
	// PTY metrics reader. Affects every run launched from inside a Claude Code session.
	public static var inheritedEnvironment: [String: String] {
		sanitized(ProcessInfo.processInfo.environment)
	}

	static func sanitized(_ environment: [String: String]) -> [String: String] {
		environment.filter { !$0.key.hasPrefix("CLAUDE") && $0.key != "AI_AGENT" }
	}

	public var environment: [String: String] {
		Claude.Feature.allCases.reduce(into: [:]) { environment, feature in
			guard !configuration.features.contains(feature),
				  case .environment(let key, let value) = Self.disable(for: feature) else { return }
			environment[key] = value
		}
	}

	static var featureVariableKeys: Set<String> {
		Set(Claude.Feature.allCases.compactMap {
			if case .environment(let key, _) = disable(for: $0) { key } else { nil }
		})
	}

}
