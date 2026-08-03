import Foundation

// Renders synthetic conversation turns into transcript records CC's resume machinery accepts:
// plain user/assistant text records mirroring the real field set, chained linearly from a
// re-rooted head. Rendering is a pure function of its inputs — timestamps come from the caller
// (never "now"), uuids from the injected generator — so the same inputs re-render byte-identically.
public enum SyntheticTranscript {

	public struct Turn: Sendable {

		public enum Role: String, Sendable {
			case user
			case assistant
		}

		public let role: Role
		public let text: String
		public let timestamp: String

		public init(role: Role, text: String, timestamp: String) {
			self.role = role
			self.text = text
			self.timestamp = timestamp
		}

	}

	// The session-constant fields a synthetic record mirrors, lifted from any real record of the
	// session being derived (the first chained one is the natural donor).
	public struct Context: Sendable {

		public let cwd: String?
		public let version: String?
		public let gitBranch: String?
		public let userType: String?

		public init(mirroring record: TranscriptRecord) {
			cwd = record.cwd
			version = record.version
			gitBranch = record.gitBranch
			userType = record.userType
		}

		init(cwd: String?, version: String?, gitBranch: String?, userType: String?) {
			self.cwd = cwd
			self.version = version
			self.gitBranch = gitBranch
			self.userType = userType
		}

	}

	// MARK: Rendering

	public static func records(
		turns: [Turn],
		sessionID: UUID,
		context: Context,
		makeUUID: () -> UUID = UUID.init
	) -> [TranscriptRecord] {
		var parentUUID: UUID?

		return turns.map { turn in
			let uuid = makeUUID()
			let rendered = RenderedRecord(turn: turn, uuid: uuid, parentUUID: parentUUID, sessionID: sessionID, context: context)
			parentUUID = uuid
			return TranscriptRecord(raw: rendered.json)
		}
	}

	// The uuid of the last rendered record — what a raw tail spliced after these turns reparents to.
	public static func leafUUID(of records: [TranscriptRecord]) -> UUID? {
		records.last { $0.uuid != nil }?.uuid
	}

}

// MARK: Encoding

// Encoding goes through Encodable so JSON string escaping is correct by construction; sorted keys
// make the bytes deterministic (key order is semantically irrelevant to CC's parser). The one
// deliberate deviation from synthesized encoding: `parentUuid` renders an explicit `null` on the
// head record, mirroring real first records, instead of omitting the key.
private struct RenderedRecord: Encodable {

	let parentUuid: String?
	let isSidechain: Bool
	let userType: String?
	let cwd: String?
	let sessionId: String
	let version: String?
	let gitBranch: String?
	let type: String
	let message: Message
	let uuid: String
	let timestamp: String

	struct Message: Encodable {

		let role: String
		let content: [Block]

		struct Block: Encodable {

			let type: String
			let text: String

		}

	}

	init(turn: SyntheticTranscript.Turn, uuid: UUID, parentUUID: UUID?, sessionID: UUID, context: SyntheticTranscript.Context) {
		parentUuid = parentUUID?.canonical
		isSidechain = false
		userType = context.userType
		cwd = context.cwd
		sessionId = sessionID.canonical
		version = context.version
		gitBranch = context.gitBranch
		type = turn.role.rawValue
		message = Message(role: turn.role.rawValue, content: [Message.Block(type: "text", text: turn.text)])
		self.uuid = uuid.canonical
		timestamp = turn.timestamp
	}

	func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Keys.self)
		try container.encode(parentUuid, forKey: .parentUuid)
		try container.encode(isSidechain, forKey: .isSidechain)
		try container.encodeIfPresent(userType, forKey: .userType)
		try container.encodeIfPresent(cwd, forKey: .cwd)
		try container.encode(sessionId, forKey: .sessionId)
		try container.encodeIfPresent(version, forKey: .version)
		try container.encodeIfPresent(gitBranch, forKey: .gitBranch)
		try container.encode(type, forKey: .type)
		try container.encode(message, forKey: .message)
		try container.encode(uuid, forKey: .uuid)
		try container.encode(timestamp, forKey: .timestamp)
	}

	private enum Keys: String, CodingKey {
		case parentUuid, isSidechain, userType, cwd, sessionId, version, gitBranch, type, message, uuid, timestamp
	}

	var json: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return String(decoding: try! encoder.encode(self), as: UTF8.self)
	}

}
