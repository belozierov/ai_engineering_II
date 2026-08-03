import Foundation
import OpsCore

// The snapshot's own account of what it holds: which paths carry quarantined segments and which resources
// each path is allowed to grant. It is read back through the sandbox like any other file, so a manifest can
// never name a path the sandbox itself would refuse.
struct SourceManifest: Decodable {

	static let fileName = "manifest.json"
	static let supportedSchemaVersion = 1

	let schemaVersion: Int
	let synthetic: Bool
	let readOnly: Bool
	let files: [File]

	// Each refusal names the axis that failed, because "invalid" alone leaves an operator no way to tell a
	// stale schema version from a repeated path, and the fixture is the thing that has to be fixed. Every
	// message stays a constant sentence in the discipline the rest of the contract uses: naming the axis is
	// safe, echoing the offending path would put untrusted text into an error.
	//
	// A repeated path is refused rather than resolved because it has no honest reading: last-wins would let
	// an entry with no markers erase the quarantine another entry declares for the same file, and first-wins
	// would do the same in the other direction — a silent downgrade of the snapshot's own labelling either
	// way. So the whole manifest fails and the sandbox refuses to come up rather than come up under-labelled.
	func validated() throws -> SourceManifest {
		guard schemaVersion == Self.supportedSchemaVersion else {
			throw ContractError("source manifest declares an unsupported schema version")
		}
		guard synthetic, readOnly else {
			throw ContractError("source manifest must declare itself synthetic and read-only")
		}
		guard Set(files.lazy.map(\.path)).count == files.count else {
			throw ContractError("source manifest repeats a file path")
		}

		return self
	}

	// Unique paths are the manifest's own invariant above, and `decoded(from:)` is the only way to get one,
	// so these two tables need no uniquing rule — there is no key for them to collide on.
	var quarantinedSegments: [String: [String]] {
		Dictionary(uniqueKeysWithValues: files.lazy.filter { !$0.quarantinedSegments.isEmpty }
			.map { ($0.path, $0.quarantinedSegments) })
	}

	var allowedResources: [String: [String]] {
		Dictionary(uniqueKeysWithValues: files.lazy.filter { !$0.allowedResources.isEmpty }
			.map { ($0.path, $0.allowedResources) })
	}

	static func decoded(from content: String) throws -> SourceManifest {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		guard let manifest = try? decoder.decode(Self.self, from: Data(content.utf8)) else {
			throw ContractError("source manifest does not decode against the supported shape")
		}

		return try manifest.validated()
	}

	struct File: Decodable {

		let path: String
		let trust: Trust
		let quarantinedSegments: [String]
		let allowedResources: [String]

		// Closed on purpose: an unknown trust label fails the whole manifest rather than being read as the
		// weaker of the two, so a snapshot cannot quietly gain a third trust level.
		enum Trust: String, Decodable {

			case untrustedData = "untrusted_data"
			case quarantined
		}
	}
}
