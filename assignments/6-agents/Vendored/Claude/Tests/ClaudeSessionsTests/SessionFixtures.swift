import ClaudeTranscript
import Foundation

// Builds synthetic session transcripts as JSONL. Records are serialized from dictionaries so field
// escaping and nesting stay correct; the shapes mirror those verified on real transcripts (CC
// 2.1.121–2.1.205), content is synthetic.
enum SessionFixtures {

	static let sessionID = UUID(uuidString: "cd63841e-53eb-4b93-97ed-a0960064f224")!
	static let cwd = "/Users/dev/Project"

	// Deliberately fake: the version is inert fixture data, and a real-looking value would read as
	// a pin to a specific CC release, which ships several times a week.
	static let version = "0.0.0-fixture"

	// MARK: Record builders

	static func userText(
		_ text: String,
		uuid: String,
		timestamp: String,
		cwd: String? = cwd,
		branch: String? = "main",
		version: String? = version,
		isMeta: Bool = false,
		isCompactSummary: Bool = false) -> String {

		var object = base(type: "user", uuid: uuid, timestamp: timestamp, cwd: cwd, branch: branch, version: version)
		object["message"] = ["role": "user", "content": text]
		if isMeta { object["isMeta"] = true }
		if isCompactSummary { object["isCompactSummary"] = true }
		return line(object)
	}

	static func assistant(
		text: String?,
		toolUse: (name: String, filePath: String)? = nil,
		uuid: String,
		timestamp: String) -> String {

		var content: [[String: Any]] = []
		if let text { content.append(["type": "text", "text": text]) }
		if let toolUse {
			content.append(["type": "tool_use", "id": "toolu_\(uuid.prefix(6))", "name": toolUse.name, "input": ["file_path": toolUse.filePath]])
		}

		var object = base(type: "assistant", uuid: uuid, timestamp: timestamp)
		object["message"] = ["role": "assistant", "content": content]
		return line(object)
	}

	static func toolResult(filePath: String, uuid: String, timestamp: String) -> String {
		var object = base(type: "user", uuid: uuid, timestamp: timestamp)
		object["message"] = ["role": "user", "content": [["tool_use_id": "toolu_x", "type": "tool_result", "content": "1\t# file"]]]
		object["toolUseResult"] = ["file": ["filePath": filePath]]
		return line(object)
	}

	static func aiTitle(_ title: String) -> String {
		line(["type": "ai-title", "aiTitle": title, "sessionId": sessionID.canonical])
	}

	static func customTitle(_ title: String) -> String {
		line(["type": "custom-title", "customTitle": title, "sessionId": sessionID.canonical])
	}

	static func mode(_ mode: String = "normal") -> String {
		line(["type": "mode", "mode": mode, "sessionId": sessionID.canonical])
	}

	// MARK: File helpers

	static func write(_ lines: [String], named name: String, in directory: URL) throws -> URL {
		let url = directory.appending(path: name)
		try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
		return url
	}

	static func write(_ lines: [String], in directory: URL) throws -> URL {
		try write(lines, named: "\(sessionID.canonical).jsonl", in: directory)
	}

	// MARK: Serialization

	private static func base(
		type: String,
		uuid: String,
		timestamp: String,
		cwd: String? = cwd,
		branch: String? = "main",
		version: String? = version) -> [String: Any] {

		var object: [String: Any] = [
			"type": type,
			"uuid": uuid,
			"sessionId": sessionID.canonical,
			"timestamp": timestamp
		]
		if let cwd { object["cwd"] = cwd }
		if let branch { object["gitBranch"] = branch }
		if let version { object["version"] = version }
		return object
	}

	private static func line(_ object: [String: Any]) -> String {
		let data = try! JSONSerialization.data(withJSONObject: object)
		return String(decoding: data, as: UTF8.self)
	}

}
