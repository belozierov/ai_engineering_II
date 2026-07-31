import ClaudeDomain
import Foundation
import JSONSchema
import OpsCore

// The inventory of the calling identity's procedures. The runtime context is injected at construction and
// is never an argument: the model names what it wants to read, never whose memory it reads from.
public struct ListProceduresTool: Claude.HostedTool {

	public let name = "list_procedures"
	public let description = "List structured procedures in the injected identity scope."

	private let memory: ProcedureMemory
	private let context: RuntimeContext

	public init(memory: ProcedureMemory, context: RuntimeContext) {
		self.memory = memory
		self.context = context
	}

	public func call(_ arguments: Arguments) async throws -> Output {
		let identifiers = try await memory.list(context)

		return Output(count: identifiers.count, procedureIDs: identifiers)
	}
}

// MARK: Arguments

public extension ListProceduresTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable, Sendable {

		public static let schema: JSONSchema = .object(
			properties: [:],
			required: [],
			additionalProperties: .boolean(false))

		public init() {}
	}
}

// MARK: Output

public extension ListProceduresTool {

	struct Output: Claude.SchemaRepresentable, Encodable, Hashable, Sendable {

		public static let schema: JSONSchema = .object(
			properties: ["count": .integer(), "procedure_ids": .array(items: .string())],
			required: ["count", "procedure_ids"])

		public let count: Int
		public let procedureIDs: [String]

		enum CodingKeys: String, CodingKey {

			case count
			case procedureIDs = "procedure_ids"
		}
	}
}
