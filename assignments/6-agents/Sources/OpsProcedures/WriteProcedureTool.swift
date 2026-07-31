import ClaudeDomain
import Foundation
import JSONSchema
import OpsCore
import OpsEvidenceGuard

// The only way a procedure ever enters durable memory. Its arguments are the record's own fields — there
// is no path argument and no free-form document argument, so the model cannot ask for a file to be adopted
// as a procedure or smuggle one in as a blob.
//
// Two preconditions are non-negotiable and both live below this tool: the write must cite usable evidence
// from the current run, and updating an existing procedure must supply that record's current content hash.
// A model that lost track of the hash re-reads the procedure; it cannot overwrite blind.
public struct WriteProcedureTool: Claude.HostedTool {

	public let name = "write_procedure"
	public let description = """
		Atomically write an evidence-backed structured procedure with conflict control. Omit expected_hash \
		to create a new procedure; to update one, pass the content_hash from read_procedure.
		"""

	private let memory: ProcedureMemory
	private let context: RuntimeContext

	public init(memory: ProcedureMemory, context: RuntimeContext) {
		self.memory = memory
		self.context = context
	}

	public func call(_ arguments: Arguments) async throws -> Output {
		let written = try await memory.write(
			context,
			procedureID: arguments.procedureID,
			title: arguments.title,
			steps: arguments.steps,
			evidenceIDs: arguments.evidenceIDs,
			expectedHash: arguments.expectedHash
		)

		return Output(procedure: ProcedureView(written.procedure))
	}
}

// MARK: Arguments

public extension WriteProcedureTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable, Sendable {

		public static let schema: JSONSchema = .object(
			properties: [
				"procedure_id": .string(
					description: "Structured name: ASCII letters, digits, underscore and hyphen only",
					minLength: 1,
					maxLength: Procedure.maximumStorageNameLength,
					pattern: Procedure.storageNamePattern),
				"title": .string(minLength: 1, maxLength: Procedure.maximumTitleLength),
				"steps": .array(
					description: "Ordered procedure steps",
					items: .string(minLength: 1, maxLength: Procedure.maximumStepLength),
					minItems: 1,
					maxItems: Procedure.maximumSteps),
				"evidence_ids": .array(
					description: "Evidence identifiers issued in this turn that back the procedure",
					items: .string(minLength: 1, maxLength: 128, pattern: Procedure.evidenceIDPattern),
					minItems: 1,
					maxItems: EvidenceGuard.maximumEvidenceIDs),
				"expected_hash": .string(
					description: "Current content_hash when updating; omit when creating",
					minLength: 64,
					maxLength: 64)
			],
			required: ["procedure_id", "title", "steps", "evidence_ids"],
			additionalProperties: .boolean(false))

		public let procedureID: String
		public let title: String
		public let steps: [String]
		public let evidenceIDs: [String]
		public let expectedHash: String?

		public init(procedureID: String, title: String, steps: [String], evidenceIDs: [String], expectedHash: String? = nil) {
			self.procedureID = procedureID
			self.title = title
			self.steps = steps
			self.evidenceIDs = evidenceIDs
			self.expectedHash = expectedHash
		}

		enum CodingKeys: String, CodingKey {

			case procedureID = "procedure_id"
			case title
			case steps
			case evidenceIDs = "evidence_ids"
			case expectedHash = "expected_hash"
		}
	}
}

// MARK: Output

public extension WriteProcedureTool {

	struct Output: Claude.SchemaRepresentable, Encodable, Hashable, Sendable {

		public static let schema: JSONSchema = .object(
			properties: ["status": .string(), "procedure": ProcedureView.schema],
			required: ["status", "procedure"])

		public let procedure: ProcedureView

		public init(procedure: ProcedureView) {
			self.procedure = procedure
		}

		public var status: String { EventStatus.completed.rawValue }

		public var contentHash: String { procedure.contentHash }

		enum CodingKeys: String, CodingKey {

			case status
			case procedure
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(status, forKey: .status)
			try container.encode(procedure, forKey: .procedure)
		}
	}
}
