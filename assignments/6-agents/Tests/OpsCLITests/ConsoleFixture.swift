import Foundation
import OpsAgent
import OpsCLI
import OpsCore
import Synchronization

// A console whose two streams are strings. Every render test reads them back verbatim, which is the only
// way to assert the one property that matters as much as the layout: in `--json` mode nothing but JSONL
// lines is on the output stream.
final class RecordingConsole: Sendable {

	private let outputText = Mutex("")
	private let errorText = Mutex("")
	private let isInteractive: Bool

	init(isInteractive: Bool = false) {
		self.isInteractive = isInteractive
	}

	// Computed because a Mutex is non-copyable: the writers reach it through self rather than through a
	// captured copy, and self cannot be captured while the console is still a stored property being set.
	var console: Console {
		Console(
			output: { [self] text in outputText.withLock { $0 += text } },
			error: { [self] text in errorText.withLock { $0 += text } },
			isInteractive: isInteractive
		)
	}

	var output: String { outputText.withLock { $0 } }

	var error: String { errorText.withLock { $0 } }

	var outputLines: [String] { Self.lines(of: output) }

	var errorLines: [String] { Self.lines(of: error) }

	private static func lines(of text: String) -> [String] {
		text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
	}
}

// MARK: Input

// The operator's keyboard as an array, plus the fact a test needs afterwards: whether the REPL read to the
// end of it or left early.
final class ScriptedInput: Sendable {

	private let remaining: Mutex<[String]>

	init(_ lines: [String]) {
		remaining = Mutex(lines)
	}

	var reader: LineReader {
		LineReader { [self] in
			remaining.withLock { lines in
				guard !lines.isEmpty else { return nil }

				return lines.removeFirst()
			}
		}
	}

	var unread: Int { remaining.withLock(\.count) }
}

// MARK: Fixtures

// The values the render tests are written against: a fixed run, fixed identifiers and a digest that looks
// like one, so a golden string is a golden string.
enum RenderFixture {

	static let identity = "identity-test-console"
	static let thread = "incident-test"
	static let run = "run-test-1"
	static let digest = String(repeating: "ab", count: 32)

	static func event(
		_ type: EventType,
		status: EventStatus = .completed,
		family: SourceFamily? = nil,
		level: MemoryLevel? = nil,
		count: Int? = nil,
		artifactID: String? = nil,
		digest: String? = nil
	) throws -> AppEvent {
		try AppEvent(
			eventType: type,
			runID: run,
			status: status,
			sourceFamily: family,
			memoryLevel: level,
			count: count,
			artifactID: artifactID,
			digest: digest
		)
	}

	static func plan(_ count: Int, artifactID: String = "plan-test-1") throws -> AppEvent {
		try event(.planSnapshot, count: count, artifactID: artifactID, digest: digest)
	}

	static func source(_ family: SourceFamily, status: EventStatus = .completed, evidenceID: String) throws -> AppEvent {
		try event(.source, status: status, family: family, count: 1, artifactID: evidenceID)
	}

	static func todos(_ items: (String, PlanSnapshotTracker.TodoItem.State)...) throws -> [PlanSnapshotTracker.TodoItem] {
		try items.map { try PlanSnapshotTracker.TodoItem(text: $0.0, state: $0.1) }
	}

	static func result(
		status: EventStatus = .completed,
		answer: String,
		toolNames: [String] = [],
		sourceIDs: [String] = []
	) throws -> TurnResult {
		try TurnResult(
			runID: run,
			identityID: identity,
			threadID: thread,
			turnStatus: status,
			answer: answer,
			toolNames: toolNames,
			sourceIDs: sourceIDs
		)
	}
}
