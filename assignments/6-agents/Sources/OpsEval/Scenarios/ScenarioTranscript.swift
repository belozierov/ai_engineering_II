import Foundation
import OpsCore

// One run as the public JSONL protocol described it. These are decoders for the stream, not the contract
// types themselves: AppEvent, TurnResult and Evidence are Encodable only, and an evaluator that read the
// in-process values would be asserting over the objects rather than over what the console published.
struct ScenarioTranscript: Sendable {

	let events: [ScenarioEvent]
	let turnResult: ScenarioTurnResult?

	// A line that is not a protocol record at all is a broken stream rather than a missing observation, so
	// it throws and the scenario reports its checks as unobserved.
	init(lines: [String]) throws {
		let decoder = JSONDecoder()
		var events: [ScenarioEvent] = []
		var turnResult: ScenarioTurnResult?

		for line in lines {
			let data = Data(line.utf8)
			switch try decoder.decode(Discriminator.self, from: data).record {
			case .event: events.append(try decoder.decode(ScenarioEvent.self, from: data))

			case .turnResult: turnResult = try decoder.decode(ScenarioTurnResult.self, from: data)

			// Local-only by contract and carrying nothing the capability rows are decided on: the plan
			// digests come from the plan_snapshot events, which is where their order is observable.
			case .plan: continue
			}
		}

		self.events = events
		self.turnResult = turnResult
	}

	private struct Discriminator: Decodable {

		let record: Kind

		enum Kind: String, Decodable {

			case event
			case plan
			case turnResult = "turn_result"
		}
	}
}

// MARK: Events

struct ScenarioEvent: Decodable, Sendable {

	let eventType: EventType
	let status: EventStatus
	let sourceFamily: SourceFamily?
	let artifactID: String?
	let digest: String?

	var isCompletedPlanSnapshot: Bool { eventType == .planSnapshot && status == .completed }

	var isCompletedSource: Bool { eventType == .source && status == .completed }

	enum CodingKeys: String, CodingKey {

		case eventType = "event_type"
		case status
		case sourceFamily = "source_family"
		case artifactID = "artifact_id"
		case digest
	}
}

// MARK: Turn result

struct ScenarioTurnResult: Decodable, Sendable {

	let turnStatus: EventStatus
	let answer: String
	let toolNames: [String]
	let evidence: [ScenarioEvidence]

	var isCompleted: Bool { turnStatus == .completed }

	// Nil when any identifier names evidence this run never reported issuing, which is a different fact
	// from citing too few families: the record and the answer disagree, so neither can be read.
	func families(of evidenceIDs: [String]) -> [SourceFamily]? {
		let issued = Dictionary(evidence.map { ($0.evidenceID, $0.provenance.sourceFamily) }) { first, _ in first }

		var families: [SourceFamily] = []
		for evidenceID in evidenceIDs {
			guard let family = issued[evidenceID] else { return nil }

			families.append(family)
		}

		return families
	}

	func evidenceIDs(from sourceID: String) -> Set<String> {
		Set(evidence.lazy.filter { $0.provenance.sourceID == sourceID }.map(\.evidenceID))
	}

	enum CodingKeys: String, CodingKey {

		case turnStatus = "turn_status"
		case answer
		case toolNames = "tool_names"
		case evidence
	}
}

struct ScenarioEvidence: Decodable, Sendable {

	let evidenceID: String
	let provenance: Provenance

	struct Provenance: Decodable, Sendable {

		let sourceFamily: SourceFamily
		let sourceID: String

		enum CodingKeys: String, CodingKey {

			case sourceFamily = "source_family"
			case sourceID = "source_id"
		}
	}

	enum CodingKeys: String, CodingKey {

		case evidenceID = "evidence_id"
		case provenance
	}
}
