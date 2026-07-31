import Foundation

public struct TokenBudgets: Hashable, Sendable {

	public static let maximumBudget = 1_000_000

	public let compactionTarget: Int
	public let compactionSoft: Int
	public let hardInput: Int
	public let responseReserve: Int

	public init(
		compactionTarget: Int = 4_000,
		compactionSoft: Int = 8_000,
		hardInput: Int = 12_000,
		responseReserve: Int = 2_000
	) throws {
		let budgets = [compactionTarget, compactionSoft, hardInput, responseReserve]
		guard budgets.allSatisfy((1...Self.maximumBudget).contains) else {
			throw ContractError("token budgets must be positive bounded integers")
		}
		guard compactionTarget < compactionSoft, compactionSoft < hardInput else {
			throw ContractError("token budgets must satisfy target < soft trigger < hard input")
		}
		guard responseReserve < hardInput else {
			throw ContractError("token budgets require response reserve below hard input")
		}

		self.compactionTarget = compactionTarget
		self.compactionSoft = compactionSoft
		self.hardInput = hardInput
		self.responseReserve = responseReserve
	}
}
