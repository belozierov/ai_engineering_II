import Foundation

// Every message is a bounded constant sentence built from a short label, so a validation failure can
// be surfaced to a model or a user without echoing the value that failed.
public struct ContractError: Error, Hashable, Sendable, CustomStringConvertible {

	public let description: String

	public init(_ description: String) {
		self.description = String(description.prefix(160))
	}
}
