import Foundation
import OpsCompaction

// The two things compaction needs from a session, and the two things the loop must never do itself:
// read back what the conversation currently is, and continue it somewhere else. Both stay inside the
// transport — the loop hands over a plan and gets a session speaking on a new identifier, never
// learning whether a transcript file, a script cursor or nothing at all stands behind it.
//
// `adopt` is all-or-nothing by contract: the derived conversation is built in full before the pointer
// moves, so a failure leaves the session exactly where it was and still usable for the next send.
// That is what makes "summarizer failure → stay on the old session" a property of this seam rather
// than of every call site.
public protocol CompactableModelSession: ModelSession {

	func history() async throws -> [MessageGroup]

	func adopt(_ plan: CompactionPlan) async throws

}
