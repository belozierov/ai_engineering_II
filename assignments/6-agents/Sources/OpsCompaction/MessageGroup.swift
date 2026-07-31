import Foundation

// One complete model round reduced to plain data: the prompt that opened it, the assistant records
// that answered it, and the tool results that came back inside it. Grouping from a transcript is one
// constructor among others — a scripted transport records the same three things and builds groups
// directly, without ever producing a transcript line.
//
// The pair bookkeeping is the whole point of the type: a boundary that leaves a tool_use on the
// summarized side and its tool_result on the raw side produces a transcript the API refuses, so a
// group states plainly whether it ends mid tool round and whether it opens with a result whose call
// happened earlier.
public struct MessageGroup: Hashable, Sendable {

	public let entries: [Entry]
	// Indices into the record array this group was built from; empty for groups built directly. Groups
	// partition their records in order, so the tail of a cut is always a contiguous suffix.
	public let recordIndices: [Int]
	// What this group costs while it stays in the context as raw records — the size the keep budget
	// spends, as opposed to the smaller summarizer payload.
	public let rawCharacterCount: Int

	public let hasUnresolvedToolUses: Bool
	public let hasOrphanToolResults: Bool

	public init(entries: [Entry], recordIndices: [Int] = [], rawCharacterCount: Int? = nil) {
		self.entries = entries
		self.recordIndices = recordIndices
		self.rawCharacterCount = rawCharacterCount ?? entries.reduce(0) { $0 + $1.characterCount }

		var pending: Set<String> = []
		// An unparsed line may be carrying anything, a tool_use included, so it counts as an unfinished
		// tool round rather than as nothing.
		var unresolved = entries.contains(.unparsed)
		var orphans = false
		for entry in entries {
			switch entry {
			case .toolUse(_, let id):
				if let id {
					pending.insert(id)
				} else {
					unresolved = true
				}

			case .toolResult(let toolUseID, _):
				if let toolUseID, pending.remove(toolUseID) != nil { continue }
				orphans = true

			case .prompt, .assistantText, .meta, .unparsed: continue
			}
		}

		hasUnresolvedToolUses = unresolved || !pending.isEmpty
		hasOrphanToolResults = orphans
	}

	public var isComplete: Bool { !hasUnresolvedToolUses && !hasOrphanToolResults }

	// MARK: Summarizer payload

	// The only rendering of a group that carries content, and it goes to one place: the summarizer
	// prompt. Events, digests and the UI see counts and sizes, never this.
	public var payloadText: String {
		let names = toolNamesByID
		return entries.map { entry in
			guard case .toolResult(let toolUseID, _) = entry else { return entry.payloadLine(toolName: nil) }

			return entry.payloadLine(toolName: toolUseID.flatMap { names[$0] })
		}.joined(separator: "\n")
	}

	public var payloadCharacterCount: Int { TokenEstimate.characterCount(of: payloadText) }

	private var toolNamesByID: [String: String] {
		entries.reduce(into: [:]) { names, entry in
			guard case .toolUse(let name, let id) = entry, let name, let id else { return }

			names[id] = name
		}
	}
}

// MARK: Entry

public extension MessageGroup {

	enum Entry: Hashable, Sendable {

		public static let maximumTextCharacters = 2_000
		public static let maximumToolResultCharacters = 500

		case prompt(String)
		case assistantText(String)
		case toolUse(name: String?, id: String?)
		case toolResult(toolUseID: String?, text: String)
		// The transcript repair claude writes on a max-turns cutoff: an isMeta user record and a
		// `model: "<synthetic>"` assistant record. They belong to the round around them and never open a
		// new one.
		case meta(role: String?, text: String)
		// A line that could not be parsed within the inspection bounds. Never a boundary, always treated
		// as a possible unfinished tool round.
		case unparsed

		// The untruncated size of what this entry contributes to the context, which is what the keep
		// budget spends — the payload rendering below is bounded, the context is not.
		public var characterCount: Int {
			switch self {
			case .prompt(let text), .assistantText(let text): TokenEstimate.characterCount(of: text)

			case .toolUse(let name, let id): TokenEstimate.characterCount(of: (name ?? "") + (id ?? ""))

			case .toolResult(_, let text): TokenEstimate.characterCount(of: text)

			case .meta(_, let text): TokenEstimate.characterCount(of: text)

			case .unparsed: 0
			}
		}

		func payloadLine(toolName: String?) -> String {
			switch self {
			case .prompt(let text): "[user] \(Self.bounded(text, maximum: Self.maximumTextCharacters))"

			case .assistantText(let text): "[assistant] \(Self.bounded(text, maximum: Self.maximumTextCharacters))"

			case .toolUse(let name, _): "[tool_use: \(name ?? Self.unknownName)]"

			case .toolResult(_, let text):
				"[tool_result: \(toolName ?? Self.unknownName)] \(Self.bounded(text, maximum: Self.maximumToolResultCharacters))"

			case .meta(let role, let text):
				"[meta \(role ?? Self.unknownName)] \(Self.bounded(text, maximum: Self.maximumTextCharacters))"

			case .unparsed: "[unparsed]"
			}
		}

		private static let unknownName = "unknown"
		private static let truncationMarker = " …[truncated]"

		private static func bounded(_ text: String, maximum: Int) -> String {
			let scalars = text.unicodeScalars
			guard scalars.count > maximum else { return text }

			return String(String.UnicodeScalarView(scalars.prefix(maximum))) + truncationMarker
		}
	}
}
