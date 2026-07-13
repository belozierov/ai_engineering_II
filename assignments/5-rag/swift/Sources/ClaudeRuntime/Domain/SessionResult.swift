// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public struct SessionResult: Sendable {

		public let output: String
		public let usage: Usage

		public init(output: String, usage: Usage) {
			self.output = output
			self.usage = usage
		}

	}

}
