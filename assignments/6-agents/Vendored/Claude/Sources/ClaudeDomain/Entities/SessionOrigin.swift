import Foundation

extension Claude {

	public enum SessionOrigin: Sendable {

		public static var new: Self { new(sessionID: UUID()) }
		public static func fork(parent: UUID) -> Self { fork(sessionID: UUID(), parent: parent) }

		case new(sessionID: UUID)
		case resume(sessionID: UUID)
		case fork(sessionID: UUID, parent: UUID)

	}

}

extension Claude.SessionOrigin {

	public var sessionID: UUID {
		switch self {
		case .new(let sessionID): sessionID
		case .resume(let sessionID): sessionID
		case .fork(let sessionID, _): sessionID
		}
	}

	public var isResumed: Bool {
		switch self {
		case .new: false
		case .resume, .fork: true
		}
	}

}
