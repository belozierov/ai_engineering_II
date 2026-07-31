import Foundation

// The single serializer for anything that leaves the process: `json` emits the public allowlist,
// `jsonlRecord` adds the spec protocol's record discriminator so several record kinds can share one
// JSONL stream. Keys are sorted so two encodes of the same event are byte-identical.
public struct PublicEventEncoder: Sendable {

	public static let recordKey = "record"
	public static let eventRecord = "event"
	public static let turnResultRecord = "turn_result"
	public static let planRecord = "plan"

	public init() {}

	public func json(for event: AppEvent) throws -> String {
		try line(encoding: event)
	}

	public func jsonlRecord(for event: AppEvent) throws -> String {
		try line(encoding: Record(event, kind: Self.eventRecord))
	}

	public func jsonlRecord(for result: TurnResult) throws -> String {
		try line(encoding: Record(result, kind: Self.turnResultRecord))
	}

	public func jsonlRecord(for plan: PlanRecord) throws -> String {
		try line(encoding: Record(plan, kind: Self.planRecord))
	}

	private func line(encoding value: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let line = String(data: try encoder.encode(value), encoding: .utf8) else {
			throw ContractError("public event encoding failed")
		}

		return line
	}

	// One wrapper for every record kind: the wrapped value writes its own fields, then the discriminator
	// joins them in the same object rather than nesting them under an envelope. Sorted keys then place
	// `record` wherever the alphabet puts it, which is what keeps a line byte-identical between encodes.
	private struct Record<Value: Encodable>: Encodable {

		enum CodingKeys: String, CodingKey {

			case record
		}

		let value: Value
		let kind: String

		init(_ value: Value, kind: String) {
			self.value = value
			self.kind = kind
		}

		func encode(to encoder: Encoder) throws {
			try value.encode(to: encoder)
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(kind, forKey: .record)
		}
	}
}
