// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public struct Model: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

		public static let opus: Model = "opus"
		public static let sonnet: Model = "sonnet"
		public static let haiku: Model = "haiku"

		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}

		public init(stringLiteral value: String) {
			self.init(rawValue: value)
		}

	}

}
