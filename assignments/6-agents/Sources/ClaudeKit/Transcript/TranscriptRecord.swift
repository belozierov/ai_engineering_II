import Foundation

// One line of a Claude Code session transcript. Parsing is tolerant by design: a line that fails
// to decode as JSON keeps its raw bytes and no identity, and every typed field degrades to nil
// independently on shape drift — unknown or changed content is preserved, never dropped. Typed
// fields cover the canonical schema this module knows (verified on CC 2.1.197–2.1.204); `raw` is
// the escape hatch for everything else.
public struct TranscriptRecord: Sendable {

	public let raw: String
	public let isDecoded: Bool
	public let type: String?
	public let uuid: UUID?
	public let parentUUID: UUID?
	public let sessionID: String?
	public let timestamp: String?
	public let isMeta: Bool
	public let cwd: String?
	public let version: String?
	public let gitBranch: String?
	public let userType: String?
	public let message: Message?

	public init(raw: String) {
		self.raw = raw
		guard let decoded = try? JSONDecoder().decode(DecodedRecord.self, from: Data(raw.utf8)) else {
			isDecoded = false
			type = nil
			uuid = nil
			parentUUID = nil
			sessionID = nil
			timestamp = nil
			isMeta = false
			cwd = nil
			version = nil
			gitBranch = nil
			userType = nil
			message = nil
			return
		}

		isDecoded = true
		type = decoded.type
		uuid = decoded.uuid.flatMap(UUID.init(uuidString:))
		parentUUID = decoded.parentUuid.flatMap(UUID.init(uuidString:))
		sessionID = decoded.sessionId
		timestamp = decoded.timestamp
		isMeta = decoded.isMeta
		cwd = decoded.cwd
		version = decoded.version
		gitBranch = decoded.gitBranch
		userType = decoded.userType
		message = decoded.message
	}

}

// MARK: Message

extension TranscriptRecord {

	// The conversational payload: role plus the text content — a plain string for typed prompts,
	// text blocks (joined) for injected content and assistant replies. Non-text blocks contribute
	// nothing to `text`; consumers needing them read `raw`.
	public struct Message: Sendable {

		public let role: String?
		public let text: String?
		// The tool_use blocks in this message's content, in order. Empty for string content and for
		// messages with no tool_use blocks.
		public let toolUses: [ToolUse]

	}

}

// MARK: ToolUse

extension TranscriptRecord {

	// A tool_use content block reduced to the fields the module surfaces: the tool name and the
	// block id. The name is an opaque string — built-in tools ("Read", "Edit") and MCP-style names
	// ("mcp__server__tool") are not distinguished here. Each field degrades to nil independently on
	// shape drift.
	public struct ToolUse: Sendable {

		public let name: String?
		public let id: String?

	}

}

// MARK: Decoding

extension TranscriptRecord {

	// Every field decodes independently via `try?`: a drifted field shape nils that field only,
	// never the record. The synthesized Decodable would throw the whole record away on any single
	// type mismatch — exactly the failure mode the format-drift tax punishes.
	private struct DecodedRecord: Decodable {

		let type: String?
		let uuid: String?
		let parentUuid: String?
		let sessionId: String?
		let timestamp: String?
		let isMeta: Bool
		let cwd: String?
		let version: String?
		let gitBranch: String?
		let userType: String?
		let message: Message?

		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: Keys.self)
			type = try? container.decode(String.self, forKey: .type)
			uuid = try? container.decode(String.self, forKey: .uuid)
			parentUuid = try? container.decode(String.self, forKey: .parentUuid)
			sessionId = (try? container.decode(String.self, forKey: .sessionId))
				?? (try? container.decode(String.self, forKey: .sessionIdSnake))
			timestamp = try? container.decode(String.self, forKey: .timestamp)
			isMeta = (try? container.decode(Bool.self, forKey: .isMeta)) ?? false
			cwd = try? container.decode(String.self, forKey: .cwd)
			version = try? container.decode(String.self, forKey: .version)
			gitBranch = try? container.decode(String.self, forKey: .gitBranch)
			userType = try? container.decode(String.self, forKey: .userType)
			message = (try? container.decode(DecodedMessage.self, forKey: .message)).map { decoded in
				Message(role: decoded.role, text: decoded.text, toolUses: decoded.toolUses)
			}
		}

		private enum Keys: String, CodingKey {
			case type, uuid, parentUuid, sessionId, timestamp, isMeta
			case cwd, version, gitBranch, userType, message
			case sessionIdSnake = "session_id"
		}

	}

	private struct DecodedMessage: Decodable {

		let role: String?
		let text: String?
		let toolUses: [TranscriptRecord.ToolUse]

		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: Keys.self)
			role = try? container.decode(String.self, forKey: .role)

			if let string = try? container.decode(String.self, forKey: .content) {
				text = string
				toolUses = []
			} else if let blocks = try? container.decode([Block].self, forKey: .content) {
				let texts = blocks.compactMap(\.text)
				text = texts.isEmpty ? nil : texts.joined(separator: "\n")
				toolUses = blocks.compactMap(\.toolUse)
			} else {
				text = nil
				toolUses = []
			}
		}

		private enum Keys: String, CodingKey {
			case role, content
		}

		// A single content block. The module surfaces text (for the joined message body) and, for
		// tool_use blocks, the tool identity (`name`, `id`). A text block carries no identity, a
		// tool_use block no `text` — each field degrades to nil independently.
		private struct Block: Decodable {

			let type: String?
			let text: String?
			let name: String?
			let id: String?

			init(from decoder: any Decoder) throws {
				let container = try? decoder.container(keyedBy: Keys.self)
				type = try? container?.decode(String.self, forKey: .type)
				text = try? container?.decode(String.self, forKey: .text)
				name = try? container?.decode(String.self, forKey: .name)
				id = try? container?.decode(String.self, forKey: .id)
			}

			// This block projected to a surfaced tool use, or nil for any non-tool_use block. Gating
			// on `type` — not on `name` — keeps a tool_use whose name drifted to nil visible as a
			// ToolUse with a nil name, rather than silently dropping it.
			var toolUse: TranscriptRecord.ToolUse? {
				guard type == "tool_use" else { return nil }
				return TranscriptRecord.ToolUse(name: name, id: id)
			}

			private enum Keys: String, CodingKey {
				case type, text, name, id
			}

		}

	}

}
