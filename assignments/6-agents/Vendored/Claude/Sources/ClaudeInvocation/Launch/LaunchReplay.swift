import Foundation
import ClaudeDomain

// Wholesale launch replay — parity by replay, not by whitelist: reproduce a recorded process
// launch as a resume-ready argv tail + environment, parsing only what must change. An unknown
// flag passes through verbatim and fails the spawn loudly — the visible, diagnosable failure
// mode; a whitelist lags the platform silently as a busted prompt cache (measured on the first
// claude-desktop parent, 2026-07-06).
public struct LaunchReplay: Equatable, Sendable {

	public let executable: URL
	// The verbatim argv tail — everything the launch carried minus transport, origin and
	// settings. Intended for `Invocation.extraArguments` (appended last, final occurrence
	// wins); that carrier is also why a caller's model/effort override is applied here, into
	// the tail — rendered before the tail it would lose to the launch's own flags.
	public let arguments: [String]
	// The launch environment minus the credential bundle. Read live, never persisted.
	public let environment: [String: String]
	// The launch's `--settings` payload, extracted for the caller's merge: a second --settings
	// flag deafens a PTY-driven child (measured: startupTimedOut), so it never rides the tail.
	public let settings: String?

	// MARK: Knowledge tables

	// The ONLY flag semantics the replay knows: transport flags are measured prefix-invisible
	// and a PTY cannot drive a stream-json/print child; origin flags are replaced by the
	// caller's own origin (rendered lowercase by Invocation); settings are extracted (above).
	private enum Strip { case flagOnly, flagAndValue }

	private static let denylist: [String: Strip] = [
		"--output-format": .flagAndValue,
		"--input-format": .flagAndValue,
		"--permission-prompt-tool": .flagAndValue,
		"--include-partial-messages": .flagOnly,
		"--replay-user-messages": .flagOnly,
		"--verbose": .flagOnly,
		"--print": .flagOnly,
		"-p": .flagOnly,
		"--resume": .flagAndValue,
		"--session-id": .flagAndValue,
		"--fork-session": .flagOnly,
		"--continue": .flagOnly,
		"--settings": .flagAndValue,
	]

	// Credentials never travel into a machine-launched session (it authenticates from the
	// CLI's credential store). The OAuth token moves with companions that promise host-side
	// refresh — stripping the token but keeping the promises is a state the platform never
	// produces, so the whole bundle goes (measured in a real claude-desktop env, 2026-07-07).
	public static let credentialKeys: Set<String> = [
		"ANTHROPIC_API_KEY",
		"CLAUDE_CODE_OAUTH_TOKEN",
		"CLAUDE_CODE_OAUTH_SCOPES",
		"CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH",
		"CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH",
	]

	// MARK: Transform

	public static func make(
		from launch: ProcessLaunch,
		model: Claude.Model? = nil,
		effort: Claude.Effort? = nil
	) -> LaunchReplay {
		let argv = Array(launch.arguments.dropFirst())
		var tail: [String] = []
		var settings: String?
		var index = 0

		while index < argv.count {
			let argument = argv[index]
			let name = String(argument.prefix(while: { $0 != "=" }))

			guard let strip = denylist[name] else {
				tail.append(argument)
				index += 1
				continue
			}

			// Both flag shapes: `--flag=value` carries its value inline, `--flag value`
			// consumes the next element.
			var value: String?
			if let separator = argument.firstIndex(of: "=") {
				value = String(argument[argument.index(after: separator)...])
			} else if case .flagAndValue = strip, index + 1 < argv.count {
				value = argv[index + 1]
				index += 1
			}
			if name == "--settings" { settings = value }
			index += 1
		}

		if let model { replace(flag: "--model", with: model.rawValue, in: &tail) }
		if let effort { replace(flag: "--effort", with: effort.rawValue, in: &tail) }

		return LaunchReplay(
			executable: URL(filePath: launch.executablePath),
			arguments: tail,
			environment: launch.environment.filter { !credentialKeys.contains($0.key) },
			settings: settings)
	}

	// Strip every existing occurrence (both shapes), then append: the tail itself is appended
	// last at render time, so the appended pair is the final occurrence and wins.
	private static func replace(flag: String, with value: String, in tail: inout [String]) {
		var kept: [String] = []
		var index = 0

		while index < tail.count {
			let argument = tail[index]
			if argument == flag {
				index += 2
				continue
			}
			if argument.hasPrefix("\(flag)=") {
				index += 1
				continue
			}
			kept.append(argument)
			index += 1
		}

		tail = kept + [flag, value]
	}

}
