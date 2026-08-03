import Foundation

// A safe storage denial: it names the rule that failed and never carries the record, the path or the
// hash that failed it, so it can reach a model, a user or a log unchanged. `isConflict` is the one
// distinction callers act on — a conflict means "re-read and try again", everything else means "stop".
public struct ProcedureStoreError: Error, Hashable, Sendable, CustomStringConvertible {

	public let reason: Reason

	public init(_ reason: Reason) {
		self.reason = reason
	}

	public var isConflict: Bool { reason.isConflict }

	public var description: String { reason.explanation }
}

// MARK: Reason

public extension ProcedureStoreError {

	enum Reason: String, CaseIterable, Hashable, Sendable {

		case absentRecord = "absent_record"
		case missingExpectedHash = "missing_expected_hash"
		case malformedExpectedHash = "malformed_expected_hash"
		case staleExpectedHash = "stale_expected_hash"
		case invalidProcedureID = "invalid_procedure_id"
		case collidingProcedureID = "colliding_procedure_id"
		case malformedRecord = "malformed_record"
		case tamperedRecord = "tampered_record"
		case mismatchedRecord = "mismatched_record"
		case recordTooLarge = "record_too_large"
		case invalidRecordFile = "invalid_record_file"
		case incompleteArtifact = "incomplete_artifact"
		case invalidArtifact = "invalid_artifact"
		case inventoryExceeded = "inventory_exceeded"
		case inventoryUnavailable = "inventory_unavailable"
		case invalidWorkspace = "invalid_workspace"
		case writeFailed = "write_failed"

		// The four hash preconditions are the only recoverable failures: each one means the caller's view of
		// the record is out of date, and re-reading it produces a write that can succeed.
		public var isConflict: Bool {
			switch self {
			case .absentRecord, .missingExpectedHash, .malformedExpectedHash, .staleExpectedHash: true

			// A colliding name and a mismatched record are both dead ends rather than conflicts: re-reading
			// produces the same answer, and the caller has to choose another name or repair its workspace.
			case .invalidProcedureID, .collidingProcedureID, .malformedRecord, .tamperedRecord, .mismatchedRecord,
				.recordTooLarge, .invalidRecordFile, .incompleteArtifact, .invalidArtifact, .inventoryExceeded,
				.inventoryUnavailable, .invalidWorkspace, .writeFailed: false
			}
		}

		public var explanation: String {
			switch self {
			case .absentRecord: "the procedure being updated does not exist"
			case .missingExpectedHash: "updating a procedure requires its current content hash"
			case .malformedExpectedHash: "the supplied procedure content hash is malformed"
			case .staleExpectedHash: "the supplied procedure content hash is stale"
			case .invalidProcedureID: "the procedure identifier is not a bounded structured name"
			case .collidingProcedureID: "another procedure already uses this identifier up to letter case"
			case .malformedRecord: "the stored procedure record is malformed"
			case .tamperedRecord: "the stored procedure record was modified outside the service"
			case .mismatchedRecord: "the stored procedure record names a different procedure"
			case .recordTooLarge: "the procedure record exceeds its bound"
			case .invalidRecordFile: "the stored procedure record is not a bounded regular file"
			case .incompleteArtifact: "the procedure workspace contains an incomplete write"
			case .invalidArtifact: "the procedure workspace contains an unrecognized artifact"
			case .inventoryExceeded: "the procedure inventory is at its bound"
			case .inventoryUnavailable: "the procedure inventory is unavailable"
			case .invalidWorkspace: "the procedure workspace is invalid"
			case .writeFailed: "the procedure write did not complete"
			}
		}
	}
}
