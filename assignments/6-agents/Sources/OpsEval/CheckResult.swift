import Foundation
import OpsCore

// One bounded public evaluator outcome. The invariants are what keep the core section honest: a SKIP is
// only ever a declared, untouched student boundary, so it must name the TODO it stands for, and no other
// state may name one — otherwise a passing run could quietly describe itself as unfinished work.
public struct CheckResult: Hashable, Sendable {

	public static let maximumMessageLength = 300
	public static let unavailableMessage = "bounded evaluator message unavailable"

	public let name: String
	public let state: ResultState
	public let message: String
	public let capabilities: [Capability]
	public let todoID: String?

	public init(
		name: String,
		state: ResultState,
		message: String,
		capabilities: [Capability] = [],
		todoID: String? = nil
	) throws {
		guard Set(capabilities).count == capabilities.count else {
			throw ContractError("result capabilities must be unique Capability values")
		}

		self.name = try name.validatedIdentifier("result name")
		self.state = state
		self.message = message.safePublicMessage()
		self.capabilities = capabilities
		self.todoID = try todoID?.validatedTodoIdentifier("result TODO identifier")

		guard state != .skip || todoID != nil else {
			throw ContractError("SKIP requires a declared student TODO identifier")
		}
		guard todoID == nil || state == .skip else {
			throw ContractError("student TODO identifiers are valid only for SKIP")
		}
	}

	// MARK: Factories

	public static func pass(_ name: String, message: String, capabilities: [Capability] = []) throws -> CheckResult {
		try CheckResult(name: name, state: .pass, message: message, capabilities: capabilities)
	}

	public static func fail(_ name: String, message: String, capabilities: [Capability] = []) throws -> CheckResult {
		try CheckResult(name: name, state: .fail, message: message, capabilities: capabilities)
	}

	public static func skip(
		_ name: String,
		message: String,
		todoID: String,
		capabilities: [Capability] = []
	) throws -> CheckResult {
		try CheckResult(name: name, state: .skip, message: message, capabilities: capabilities, todoID: todoID)
	}

	public static func unavailable(_ name: String, message: String) throws -> CheckResult {
		try CheckResult(name: name, state: .unavailable, message: message)
	}

	// MARK: Rendering

	var renderedLine: String { "  [\(state.rawValue)] \(name): \(message)" }
}

private extension String {

	// The student TODO shape the exercise declares: U4-1 through U4-6, then a bounded lowercase slug.
	func validatedTodoIdentifier(_ label: String) throws -> String {
		let scalars = Array(unicodeScalars)
		guard (6...85).contains(scalars.count), scalars[0] == "U", scalars[1] == "4", scalars[2] == "-",
			("1"..."6").contains(scalars[3]), scalars[4] == "-",
			scalars[5...].allSatisfy(\.isTodoSlugBody) else {
			throw ContractError("\(label) is invalid")
		}

		return self
	}
}

private extension Unicode.Scalar {

	var isTodoSlugBody: Bool { ("0"..."9").contains(self) || ("a"..."z").contains(self) || self == "-" }
}

// MARK: Encodable

extension CheckResult: Encodable {

	enum CodingKeys: String, CodingKey {

		case name
		case state
		case message
		case capabilities
		case todoID = "todo_id"
	}

	// An absent TODO identifier is omitted rather than encoded as null, so the public shape of a row says
	// only what the row actually claims.
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(name, forKey: .name)
		try container.encode(state, forKey: .state)
		try container.encode(message, forKey: .message)
		try container.encode(capabilities, forKey: .capabilities)
		try container.encodeIfPresent(todoID, forKey: .todoID)
	}
}
