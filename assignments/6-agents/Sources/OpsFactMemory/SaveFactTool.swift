import ClaudeDomain
import Foundation
import JSONSchema
import OpsCore
import OpsEvidenceGuard

// The model-visible surface of a durable fact write. Identity, thread and run are stored properties bound
// by the turn runner rather than arguments, so nothing the model writes can reach the namespace the write
// lands in — the same guarantee the Python tool gets from hidden runtime injection.
//
// A blocked write throws instead of returning a payload: the caller must be able to tell a stored fact
// from a refused one, and the Python contract expects the guard's error to surface at the call site.
public struct SaveFactTool: Claude.HostedTool {

	public let name = "save_fact"
	public let description = """
		Save one evidence-backed fact in identity-scoped durable memory. Current-run evidence is required; \
		evidence IDs are not stored.
		"""

	private let service: FactMemoryService
	private let context: RuntimeContext

	public init(service: FactMemoryService, context: RuntimeContext) {
		self.service = service
		self.context = context
	}

	public func call(_ arguments: Arguments) async throws -> Output {
		let fact = try await service.save(text: arguments.text, evidenceIDs: arguments.evidenceIDs, context: context)

		return Output(factID: fact.factID, provenance: fact.provenance.map(ProvenancePayload.init))
	}
}

// MARK: Arguments

public extension SaveFactTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		public static let schema: JSONSchema = .object(
			properties: [
				"text": .string(
					description: "One bounded fact worth remembering across threads of this identity.",
					minLength: 1,
					maxLength: Fact.maximumTextLength
				),
				"evidence_ids": .array(
					description: "Current-run evidence IDs that back the fact. Stored provenance is derived from them.",
					items: .string(minLength: 1, maxLength: 128, pattern: "[A-Za-z0-9][A-Za-z0-9._:-]{0,127}"),
					minItems: 1,
					maxItems: EvidenceGuard.maximumEvidenceIDs,
					uniqueItems: true
				)
			],
			required: ["text", "evidence_ids"]
		)

		public let text: String
		public let evidenceIDs: [String]

		enum CodingKeys: String, CodingKey {

			case text
			case evidenceIDs = "evidence_ids"
		}
	}
}

// MARK: Output

public extension SaveFactTool {

	struct Output: Encodable, Sendable {

		public let status = "ok"
		public let factID: String
		public let provenance: [ProvenancePayload]
		// Nothing source-derived comes back from a write, so there is no untrusted text in this payload.
		public let untrustedData = false

		enum CodingKeys: String, CodingKey {

			case status
			case factID = "fact_id"
			case provenance
			case untrustedData = "untrusted_data"
		}
	}
}
