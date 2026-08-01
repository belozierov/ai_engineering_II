extension Claude {

	public struct SessionResult: Sendable {

		// A turn that stopped at a limit instead of finishing: the transcript persisted and the
		// caller can resume, so the cutoff is a returned fact rather than a thrown error.
		public struct Pause: Sendable {

			public let terminalReason: String?
			public let numTurns: Int?
			public let errors: [String]

			public init(terminalReason: String?, numTurns: Int?, errors: [String]) {
				self.terminalReason = terminalReason
				self.numTurns = numTurns
				self.errors = errors
			}

		}

		public let output: String
		public let usage: Usage
		public let pause: Pause?

		public init(output: String, usage: Usage, pause: Pause? = nil) {
			self.output = output
			self.usage = usage
			self.pause = pause
		}

	}

}
