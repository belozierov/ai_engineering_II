import ClaudeKit
import Foundation
import OpsCompaction
import OpsCore

// The file half of the live session swap: where a session's own transcript is, and how the derived
// one is written beside it. Kept apart from the session actor because none of it is state — it is one
// read and one write over paths the transport owns.
//
// The whole derived transcript is assembled in memory and placed under a fresh identifier; the donor
// file is only ever read. That is the atomicity: there is no half-swapped state to recover from,
// because nothing the old session depends on is touched at all.
struct SessionTranscripts: Sendable {

	// The assistant half of the synthetic head. A user turn alone would leave the derived transcript
	// ending on an unanswered prompt, and the resumed session would read its own summary as the thing
	// it still has to respond to.
	static let acknowledgement = """
		Understood. The summary above is the earlier part of this investigation; the messages that follow \
		are its recent, unsummarized part. I will continue from there.
		"""

	// CC's own timestamp shape: UTC, milliseconds, `Z`.
	private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

	let projects: ClaudeProjectsDirectory
	let store: DerivedSessionStore
	let workingDirectory: URL

	func read(_ sessionID: UUID) throws -> Reading {
		guard let url = projects.transcriptURL(for: sessionID, in: workingDirectory) else {
			throw ContractError("compaction cannot locate the transcript of the current session")
		}

		return Reading(url: url, transcript: try Transcript(contentsOf: url))
	}

	// The canonical splice: a re-rooted synthetic head, then the plan's tail records with their session
	// identifier rewritten and the first of them reparented onto the head's leaf.
	func derived(from reading: Reading, plan: CompactionPlan, at date: Date = Date()) throws -> DerivedSessionStore.Session {
		guard let donor = reading.transcript.leaf else {
			throw ContractError("compaction requires a chained donor transcript")
		}

		let sessionID = UUID()
		let timestamp = date.formatted(Self.timestampFormat)
		let head = SyntheticTranscript.records(
			turns: [
				SyntheticTranscript.Turn(role: .user, text: plan.headText, timestamp: timestamp),
				SyntheticTranscript.Turn(role: .assistant, text: Self.acknowledgement, timestamp: timestamp)
			],
			sessionID: sessionID,
			context: SyntheticTranscript.Context(mirroring: donor)
		)
		guard let leaf = SyntheticTranscript.leafUUID(of: head) else {
			throw ContractError("compaction produced no synthetic head to splice onto")
		}

		return try store.place(records: head + tail(of: plan, in: reading, sessionID: sessionID, leaf: leaf),
			besides: reading.url, id: sessionID)
	}

	private func tail(of plan: CompactionPlan, in reading: Reading, sessionID: UUID, leaf: UUID) throws
		-> [TranscriptRecord] {
		let records = reading.transcript.records
		let indices = plan.tailRecordIndices
		guard let first = indices.first, indices.allSatisfy(records.indices.contains) else {
			throw ContractError("compaction plan names records outside the transcript it planned against")
		}

		return [records[first].rewritingSessionID(to: sessionID).reparented(to: leaf)]
			+ indices.dropFirst().map { records[$0].rewritingSessionID(to: sessionID) }
	}

	// One transcript read, kept whole. The plan's record indices point into exactly this array, so the
	// splice reuses the read the plan was computed from instead of a second one that may have grown.
	struct Reading: Sendable {

		let url: URL
		let transcript: Transcript
	}
}
