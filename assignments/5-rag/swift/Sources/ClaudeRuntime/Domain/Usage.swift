// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public struct Usage: Sendable {

		public let inputTokens: Int
		public let outputTokens: Int
		public let cacheCreationTokens: Int
		public let cacheReadTokens: Int
		public let costUSD: Double?
		public let duration: Duration?

		public init(
			inputTokens: Int,
			outputTokens: Int,
			cacheCreationTokens: Int,
			cacheReadTokens: Int,
			costUSD: Double? = nil,
			duration: Duration? = nil) {
			self.inputTokens = inputTokens
			self.outputTokens = outputTokens
			self.cacheCreationTokens = cacheCreationTokens
			self.cacheReadTokens = cacheReadTokens
			self.costUSD = costUSD
			self.duration = duration
		}

	}

}
