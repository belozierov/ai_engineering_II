// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation

extension Claude {

	public protocol Session: Sendable {
		
		var id: UUID { get }
		
		func send(_ input: String) async throws -> SessionResult
		
	}

}
