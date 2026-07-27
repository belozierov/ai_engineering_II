// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public protocol CreateSessionUseCase: Sendable {
		
		func create(_ configuration: SessionConfiguration, origin: SessionOrigin) -> Session
		
	}

}

extension Claude.CreateSessionUseCase {

	public func create(_ configuration: Claude.SessionConfiguration) -> Claude.Session {
		create(configuration, origin: .new)
	}

}
