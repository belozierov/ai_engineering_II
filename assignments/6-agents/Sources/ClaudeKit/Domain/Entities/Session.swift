import Foundation

extension Claude {

	public protocol Session: Sendable {
		
		var id: UUID { get }
		
		func send(_ input: String) async throws -> SessionResult
		
	}

}
