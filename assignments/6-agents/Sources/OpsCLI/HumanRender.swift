import Foundation
import OpsAgent
import OpsCore

// The assignment's trace format, as pure text. Every line the operator console prints in human mode is
// built here and nowhere else, so the block layout the manual scenarios describe is one testable value
// rather than a print statement per branch.
//
// No colors: the reference CLI paints its output, and the assignment's own transcript of that output is
// plain — a golden test cannot hold escape sequences that depend on a terminal, and a trace pasted into
// results.md would carry them verbatim.
//
// What may appear here is metadata and the final answer. Event fields are identifiers, counts and
// digests by construction; the answer is the model's, already validated by the grounding policy. Source
// bodies, prompts, tool bodies, memory contents and provider errors have no rendering at all.
public enum HumanRender {

	public static let activityHeader = "Activity"
	public static let plansHeader = "Plans observed this turn"
	public static let answerHeader = "Answer"
	public static let loadingStatus = "loading"

	// The digest is a fingerprint the operator compares between lines, not a value anyone reads whole.
	static let digestPrefixLength = 12

	public static func context(identity: String, thread: String) -> String {
		"""
		Context
		  identity: \(identity)
		  thread:   \(thread)
		"""
	}

	public static func status(_ status: String) -> String { "Status \(status)" }

	public static func status(_ status: EventStatus) -> String { Self.status(status.rawValue) }

	// MARK: Activity

	public static func activity(_ event: AppEvent) -> String {
		"  \(event.status.rawValue)  \(message(for: event))  \(details(of: event).joined(separator: "  "))"
	}

	private static func message(for event: AppEvent) -> String {
		switch event.eventType {
		case .planSnapshot: "updated plan (\(event.count ?? 0) items)"

		case .source: event.sourceFamily.map { "collected \($0.rawValue) evidence" } ?? fallback(for: event)

		case .memory: event.memoryLevel.map { "updated \($0.rawValue) memory" } ?? fallback(for: event)

		case .compaction: "compacted conversation history"

		case .turn: "turn finished"
		}
	}

	// Unreachable through the event contract — a source event without a family does not validate — and
	// kept anyway, because the alternative to a readable fallback is a crash in the renderer.
	private static func fallback(for event: AppEvent) -> String {
		event.eventType.rawValue.replacingOccurrences(of: "_", with: " ")
	}

	private static func details(of event: AppEvent) -> [String] {
		var details = ["run=\(event.runID)"]
		if let artifactID = event.artifactID {
			// A source event's artifact is the evidence identifier the answer has to cite, so it is named as
			// one; every other family's artifact is just an artifact.
			details.append("\(event.eventType == .source ? "evidence" : "artifact")=\(artifactID)")
		}
		if let digest = event.digest {
			details.append("digest=\(digest.prefix(digestPrefixLength))...")
		}

		return details
	}

	// MARK: Plans

	public static func plans(_ snapshots: [[PlanSnapshotTracker.TodoItem]]) -> String? {
		guard !snapshots.isEmpty else { return nil }

		var lines = [plansHeader]
		for (index, snapshot) in snapshots.enumerated() {
			lines.append("  Plan \(index + 1)")
			lines.append(contentsOf: snapshot.map { "    \(glyph(for: $0.state)) [\($0.state.rawValue)] \($0.text)" })
		}

		return lines.joined(separator: "\n")
	}

	private static func glyph(for state: PlanSnapshotTracker.TodoItem.State) -> String {
		switch state {
		case .pending: "○"

		case .inProgress: "→"

		case .completed: "✓"
		}
	}

	// MARK: Answer

	public static func answer(_ text: String) -> String {
		let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		guard !normalized.isEmpty else { return answerHeader }

		return "\(answerHeader)\n\(normalized)"
	}

	// MARK: Whole turn

	// The same pieces the streaming renderer prints, in the order it prints them — one value a golden test
	// can hold, and the definition the renderer follows rather than a second copy of the layout.
	public static func turn(
		identity: String,
		thread: String,
		events: [AppEvent],
		plans snapshots: [[PlanSnapshotTracker.TodoItem]],
		result: TurnResult
	) -> String {
		var blocks = [context(identity: identity, thread: thread), status(loadingStatus), activityHeader]
		blocks.append(contentsOf: events.map(activity))
		if let block = plans(snapshots) { blocks.append(block) }
		blocks.append(answer(result.answer))
		blocks.append(status(result.turnStatus))

		return blocks.joined(separator: "\n")
	}
}
