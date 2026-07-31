import Foundation

// The single serializer for anything that leaves the process: `json` emits the public allowlist,
// `jsonlRecord` adds the spec protocol's record discriminator so several record kinds can share one
// JSONL stream. Keys are sorted so two encodes of the same event are byte-identical.
public struct PublicEventEncoder: Sendable {

	public static let recordKey = "record"
	public static let eventRecord = "event"

	public init() {}

	public func json(for event: AppEvent) throws -> String {
		try line(encoding: event)
	}

	public func jsonlRecord(for event: AppEvent) throws -> String {
		try line(encoding: Record(event: event))
	}

	private func line(encoding value: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let line = String(data: try encoder.encode(value), encoding: .utf8) else {
			throw ContractError("public event encoding failed")
		}

		return line
	}

	private struct Record: Encodable {

		enum CodingKeys: String, CodingKey {

			case record
		}

		let event: AppEvent

		func encode(to encoder: Encoder) throws {
			try event.encode(to: encoder)
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(PublicEventEncoder.eventRecord, forKey: .record)
		}
	}
}
