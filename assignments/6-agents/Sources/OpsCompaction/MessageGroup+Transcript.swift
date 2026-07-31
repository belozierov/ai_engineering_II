import Foundation
import ClaudeTranscript

public extension MessageGroup {

	// Records partition into groups in transcript order: every record lands in exactly one group, so a
	// tail slice is always a contiguous suffix of the file. Only a real user prompt opens a group — a
	// user record carrying tool_result blocks continues the round it answers, and the isMeta /
	// "<synthetic>" repair pair claude writes on a max-turns cutoff attaches to whatever surrounds it.
	static func grouping(_ records: [TranscriptRecord]) -> [MessageGroup] {
		var groups: [MessageGroup] = []
		var entries: [Entry] = []
		var indices: [Int] = []
		var rawCharacters = 0

		func closeGroup() {
			guard !indices.isEmpty else { return }

			groups.append(MessageGroup(entries: entries, recordIndices: indices, rawCharacterCount: rawCharacters))
			entries = []
			indices = []
			rawCharacters = 0
		}

		for (index, record) in records.enumerated() {
			let classified = RecordClassification(record: record)
			if classified.opensGroup { closeGroup() }

			entries += classified.entries
			indices.append(index)
			rawCharacters += TokenEstimate.characterCount(of: record.raw)
		}
		closeGroup()

		return groups
	}
}

// MARK: Classification

// What one transcript line contributes to the group being assembled, and whether it opens a new one.
private struct RecordClassification {

	let entries: [MessageGroup.Entry]
	let opensGroup: Bool

	init(record: TranscriptRecord) {
		guard record.isDecoded, let inspected = InspectedLine(raw: record.raw) else {
			entries = [.unparsed]
			opensGroup = false
			return
		}

		let role = record.message?.role
		let text = record.message?.text ?? ""
		guard !record.isMeta, !inspected.isSyntheticModel else {
			entries = [.meta(role: role, text: text)]
			opensGroup = false
			return
		}

		switch role {
		case "user":
			// Tool results arrive as user-role records. They answer the call in the round already open,
			// so they continue it; only a record with no result blocks is a fresh prompt.
			guard inspected.toolResults.isEmpty else {
				let results = inspected.toolResults.map { MessageGroup.Entry.toolResult(toolUseID: $0.toolUseID, text: $0.text) }
				entries = text.isEmpty ? results : results + [.prompt(text)]
				opensGroup = false
				return
			}

			entries = [.prompt(text)]
			opensGroup = true

		case "assistant":
			let uses = (record.message?.toolUses ?? []).map { MessageGroup.Entry.toolUse(name: $0.name, id: $0.id) }
			entries = (text.isEmpty ? [] : [.assistantText(text)]) + uses
			opensGroup = false

		default:
			// Chained state records — titles, snapshots, mode lines. They carry no conversation but they
			// do carry bytes, so they stay in the group rather than vanishing from the index partition.
			entries = []
			opensGroup = false
		}
	}
}

// MARK: Raw inspection

// tool_result blocks and the synthetic-model marker are not part of the typed record model, so they
// are read straight from the line — under explicit bounds, because this parses attacker-influenced
// tool output. Anything past a bound is not guessed at: the line becomes unparsed, which makes its
// group ineligible for the summarized side of a cut.
private struct InspectedLine {

	static let maximumLineBytes = 1 << 20
	static let maximumBlocks = 256
	static let maximumToolResultCharacters = 4_000
	static let maximumToolUseIDCharacters = 128
	static let syntheticModel = "<synthetic>"

	let isSyntheticModel: Bool
	let toolResults: [ToolResult]

	init?(raw: String) {
		let data = Data(raw.utf8)
		guard data.count <= Self.maximumLineBytes,
			let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

		let message = line["message"] as? [String: Any]
		isSyntheticModel = (message?["model"] as? String) == Self.syntheticModel

		guard let blocks = message?["content"] as? [Any] else {
			toolResults = []
			return
		}
		guard blocks.count <= Self.maximumBlocks else { return nil }

		toolResults = blocks.compactMap(ToolResult.init)
	}

	struct ToolResult: Hashable, Sendable {

		let toolUseID: String?
		let text: String

		init?(block: Any) {
			guard let block = block as? [String: Any], block["type"] as? String == "tool_result" else { return nil }

			let identifier = block["tool_use_id"] as? String
			toolUseID = identifier.flatMap { $0.count <= InspectedLine.maximumToolUseIDCharacters ? $0 : nil }
			text = String(Self.text(of: block["content"]).prefix(InspectedLine.maximumToolResultCharacters))
		}

		// Tool result content is a plain string or a block list; anything else contributes no text but
		// still counts as a result, so the pairing stays honest.
		private static func text(of content: Any?) -> String {
			if let string = content as? String { return string }
			guard let blocks = content as? [Any], blocks.count <= InspectedLine.maximumBlocks else { return "" }

			return blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n")
		}
	}
}
