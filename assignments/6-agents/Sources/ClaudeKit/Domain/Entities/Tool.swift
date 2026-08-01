extension Claude {

	public struct Tool: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}

		public init(stringLiteral value: String) {
			self.init(rawValue: value)
		}

	}

}
