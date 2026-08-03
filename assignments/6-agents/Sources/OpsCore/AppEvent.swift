import Foundation

public enum EventType: String, CaseIterable, Codable, Sendable {

	case source
	case memory
	case compaction
	case planSnapshot = "plan_snapshot"
	case turn
}

public enum EventStatus: String, CaseIterable, Codable, Sendable {

	case started
	case completed
	case blocked
	case cancelled
	case budgetExceeded = "budget_exceeded"
	case failed

	public var isTerminal: Bool { self != .started }
}

public enum MemoryLevel: String, CaseIterable, Codable, Sendable {

	case working
	case fact
	case procedure
}

// The closed, metadata-only envelope every interface consumes. There is structurally no content
// field: an event can name what happened and which artifact it happened to, never what was read.
public struct AppEvent: Hashable, Sendable {

	public static let currentSchemaVersion = 1
	public static let maximumCount = 1_000_000

	public let schemaVersion: Int
	public let eventType: EventType
	public let runID: String
	public let status: EventStatus
	public let sourceFamily: SourceFamily?
	public let memoryLevel: MemoryLevel?
	public let count: Int?
	public let artifactID: String?
	public let digest: String?

	public init(
		schemaVersion: Int = AppEvent.currentSchemaVersion,
		eventType: EventType,
		runID: String,
		status: EventStatus,
		sourceFamily: SourceFamily? = nil,
		memoryLevel: MemoryLevel? = nil,
		count: Int? = nil,
		artifactID: String? = nil,
		digest: String? = nil
	) throws {
		guard schemaVersion == Self.currentSchemaVersion else {
			throw ContractError("event schema version is unsupported")
		}
		if let count, !(0...Self.maximumCount).contains(count) {
			throw ContractError("event count must be a bounded non-negative integer")
		}

		self.schemaVersion = schemaVersion
		self.eventType = eventType
		self.runID = try runID.validatedIdentifier("event run")
		self.status = status
		self.sourceFamily = sourceFamily
		self.memoryLevel = memoryLevel
		self.count = count
		self.artifactID = try artifactID?.validatedIdentifier("event artifact identifier")
		self.digest = try digest?.validatedDigest("event digest")

		try validateFieldTable()
	}

	// MARK: Field table

	private var presentFields: Set<Field> {
		var fields: Set<Field> = []
		if sourceFamily != nil { fields.insert(.sourceFamily) }
		if memoryLevel != nil { fields.insert(.memoryLevel) }
		if count != nil { fields.insert(.count) }
		if artifactID != nil { fields.insert(.artifactID) }
		if digest != nil { fields.insert(.digest) }

		return fields
	}

	private func validateFieldTable() throws {
		let present = presentFields
		guard eventType.requiredFields.isSubset(of: present), present.isSubset(of: eventType.allowedFields) else {
			throw ContractError("event fields do not match the event type")
		}
		guard eventType.allowedStatuses.contains(status) else {
			throw ContractError("\(eventType.rawValue) event status is unsupported")
		}
	}
}

// MARK: Optional fields

public extension AppEvent {

	enum Field: String, CaseIterable, Sendable {

		case sourceFamily = "source_family"
		case memoryLevel = "memory_level"
		case count
		case artifactID = "artifact_id"
		case digest
	}
}

extension EventType {

	var requiredFields: Set<AppEvent.Field> {
		switch self {
		case .source: [.sourceFamily, .count, .artifactID]

		case .memory: [.memoryLevel, .count]

		case .compaction, .planSnapshot: [.count, .artifactID, .digest]

		case .turn: []
		}
	}

	var allowedFields: Set<AppEvent.Field> {
		switch self {
		case .memory: requiredFields.union([.artifactID])

		case .source, .compaction, .planSnapshot, .turn: requiredFields
		}
	}

	var allowedStatuses: Set<EventStatus> {
		switch self {
		case .source: [.completed, .blocked, .failed]

		case .compaction: [.completed, .failed]

		case .planSnapshot: [.completed]

		case .memory, .turn: Set(EventStatus.allCases)
		}
	}
}

// MARK: Encodable

extension AppEvent: Encodable {

	enum CodingKeys: String, CodingKey {

		case schemaVersion = "schema_version"
		case eventType = "event_type"
		case runID = "run_id"
		case status
		case sourceFamily = "source_family"
		case memoryLevel = "memory_level"
		case count
		case artifactID = "artifact_id"
		case digest
	}

	// This is the whole public allowlist. Anything not listed here cannot leave the process through an
	// event, which is why absent optionals are omitted instead of encoded as null.
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(schemaVersion, forKey: .schemaVersion)
		try container.encode(eventType, forKey: .eventType)
		try container.encode(runID, forKey: .runID)
		try container.encode(status, forKey: .status)
		try container.encodeIfPresent(sourceFamily, forKey: .sourceFamily)
		try container.encodeIfPresent(memoryLevel, forKey: .memoryLevel)
		try container.encodeIfPresent(count, forKey: .count)
		try container.encodeIfPresent(artifactID, forKey: .artifactID)
		try container.encodeIfPresent(digest, forKey: .digest)
	}
}
