extension Claude {

	public struct Model: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

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
