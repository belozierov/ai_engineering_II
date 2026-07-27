// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public struct Tool: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

		public static let read: Tool = "Read"
		public static let glob: Tool = "Glob"
		public static let grep: Tool = "Grep"
		public static let agent: Tool = "Agent"
		public static let write: Tool = "Write"

		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}

		public init(stringLiteral value: String) {
			self.init(rawValue: value)
		}

	}

}
