import Foundation

// What one finished turn is allowed to say about itself. The answer is the only free text in it; every
// other field is an identifier, a bounded list of identifiers, or evidence — which carries provenance
// and never content. That is what makes the record safe to write to a stream a shim reads: a reader
// learns which families were touched and which citations were issued, never what any of them said.
//
// `turnStatus` reuses EventStatus and requires a terminal one. A turn result describes a turn that has
// finished, so `started` is not a value this contract has; a parallel enum would only invite the two to
// drift apart.
public struct TurnResult: Hashable, Sendable {

	public static let maximumAnswerLength = 32_768
	public static let maximumNames = 128
	public static let maximumEvidence = 128

	public let runID: String
	public let identityID: String
	public let threadID: String
	public let turnStatus: EventStatus
	public let answer: String
	public let toolNames: [String]
	public let sourceIDs: [String]
	public let quarantinedSegments: [String]
	public let evidence: [Evidence]

	public init(
		runID: String,
		identityID: String,
		threadID: String,
		turnStatus: EventStatus,
		answer: String,
		toolNames: [String] = [],
		sourceIDs: [String] = [],
		quarantinedSegments: [String] = [],
		evidence: [Evidence] = []
	) throws {
		guard turnStatus.isTerminal else { throw ContractError("turn status must be terminal") }
		guard evidence.count <= Self.maximumEvidence else { throw ContractError("turn evidence must be a bounded list") }

		self.runID = try runID.validatedIdentifier("turn run")
		self.identityID = try identityID.validatedIdentifier("turn identity")
		self.threadID = try threadID.validatedIdentifier("turn thread")
		self.turnStatus = turnStatus
		// An empty answer is a fact about a cancelled or failed turn, not a malformed record: the guardrail
		// supplies refusal text where there is something to refuse, and nothing where the turn never got that
		// far.
		self.answer = try answer.validatedText("turn answer", maximum: Self.maximumAnswerLength, allowEmpty: true)
		self.toolNames = try toolNames.validatedNames("turn tool names")
		self.sourceIDs = try sourceIDs.validatedNames("turn source identifiers")
		self.quarantinedSegments = try quarantinedSegments.validatedNames("turn quarantine markers")
		self.evidence = evidence
	}

	// The trusted triple is the runner's, never the model's, so the loop hands over the context it already
	// holds rather than restating three identifiers a caller could mismatch.
	public init(
		_ context: RuntimeContext,
		turnStatus: EventStatus,
		answer: String,
		toolNames: [String] = [],
		sourceIDs: [String] = [],
		quarantinedSegments: [String] = [],
		evidence: [Evidence] = []
	) throws {
		try self.init(
			runID: context.runID,
			identityID: context.identityID,
			threadID: context.threadID,
			turnStatus: turnStatus,
			answer: answer,
			toolNames: toolNames,
			sourceIDs: sourceIDs,
			quarantinedSegments: quarantinedSegments,
			evidence: evidence
		)
	}
}

private extension Array<String> {

	func validatedNames(_ label: String) throws -> [String] {
		guard count <= TurnResult.maximumNames else { throw ContractError("\(label) must be a bounded list") }

		return try map { try $0.validatedIdentifier(label) }
	}
}

// MARK: Encodable

// The turn_result half of the JSONL protocol, minus the `record` discriminator the stream writer adds —
// the same split PublicEventEncoder makes for events, so one serializer owns the discriminator and this
// type owns its own fields.
extension TurnResult: Encodable {

	enum CodingKeys: String, CodingKey {

		case runID = "run_id"
		case identityID = "identity_id"
		case threadID = "thread_id"
		case turnStatus = "turn_status"
		case answer
		case toolNames = "tool_names"
		case sourceIDs = "source_ids"
		case quarantinedSegments = "quarantined_segments"
		case evidence
	}
}

// Evidence and its provenance are Encodable only here, where the public shape of a turn record is
// defined: the contract types themselves stay serialization-free, and the one place that writes them out
// is the one place that has to agree with the protocol.
extension ProvenanceRef: Encodable {

	enum CodingKeys: String, CodingKey {

		case sourceFamily = "source_family"
		case sourceID = "source_id"
		case contentSHA256 = "content_sha256"
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(sourceFamily, forKey: .sourceFamily)
		try container.encode(sourceID, forKey: .sourceID)
		try container.encode(contentSHA256, forKey: .contentSHA256)
	}
}

extension Evidence: Encodable {

	enum CodingKeys: String, CodingKey {

		case evidenceID = "evidence_id"
		case identityID = "identity_id"
		case runID = "run_id"
		case provenance
		case status
		case trust
		case allowedResources = "allowed_resources"
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(evidenceID, forKey: .evidenceID)
		try container.encode(identityID, forKey: .identityID)
		try container.encode(runID, forKey: .runID)
		try container.encode(provenance, forKey: .provenance)
		try container.encode(status, forKey: .status)
		try container.encode(trust, forKey: .trust)
		try container.encode(allowedResources, forKey: .allowedResources)
	}
}
