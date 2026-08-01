import Foundation

extension Claude {

	public enum SessionOrigin: Sendable {

		public static var new: Self { new(sessionID: UUID()) }

		case new(sessionID: UUID)
		case resume(sessionID: UUID)

	}

}

extension Claude.SessionOrigin {

	var sessionID: UUID {
		switch self {
		case .new(let sessionID): sessionID
		case .resume(let sessionID): sessionID
		}
	}

}
