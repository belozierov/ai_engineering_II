import Foundation
import ClaudeTranscript

// Hand-built JSONL lines in the shape claude writes them: typed prompts as plain string content,
// assistant turns as block lists, tool results as user-role records, plus the repair pair and a torn
// line. The fixtures go through TranscriptRecord's own parser, so the tests exercise the real decode
// path rather than a stand-in.
enum TranscriptFixture {

	static func prompt(_ text: String) -> TranscriptRecord {
		record(["type": "user", "message": ["role": "user", "content": text]])
	}

	static func assistant(_ text: String) -> TranscriptRecord {
		record([
			"type": "assistant",
			"message": ["role": "assistant", "model": "claude-haiku-4-5", "content": [["type": "text", "text": text]]]
		])
	}

	static func toolCall(name: String, id: String, thinking: String? = nil) -> TranscriptRecord {
		let thoughts: [[String: Any]] = thinking.map { [["type": "text", "text": $0]] } ?? []
		let call: [String: Any] = ["type": "tool_use", "id": id, "name": name, "input": ["path": "logs/checkout.log"]]
		return record([
			"type": "assistant",
			"message": ["role": "assistant", "model": "claude-haiku-4-5", "content": thoughts + [call]]
		])
	}

	static func toolResult(id: String, text: String) -> TranscriptRecord {
		record([
			"type": "user",
			"message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]]
		])
	}

	// The two records claude appends when --max-turns cuts a turn off: neither may open a group.
	static func continuation() -> TranscriptRecord {
		record([
			"type": "user",
			"isMeta": true,
			"message": ["role": "user", "content": "Continue from where you left off."]
		])
	}

	static func syntheticAssistant() -> TranscriptRecord {
		record([
			"type": "assistant",
			"message": [
				"role": "assistant",
				"model": "<synthetic>",
				"content": [["type": "text", "text": "No response requested."]]
			]
		])
	}

	static func torn() -> TranscriptRecord {
		TranscriptRecord(raw: #"{"type":"assistant","message":{"role":"assis"#)
	}

	static func stateLine() -> TranscriptRecord {
		record(["type": "summary", "aiTitle": "Synthetic checkout investigation"])
	}

	private static func record(_ object: [String: Any]) -> TranscriptRecord {
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
			preconditionFailure("transcript fixtures must be encodable")
		}

		return TranscriptRecord(raw: String(decoding: data, as: UTF8.self))
	}
}
