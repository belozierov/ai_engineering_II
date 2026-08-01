import Foundation

// The one seam where an evidence identifier and the untrusted text it stands for are both in hand. Every
// published surface carries evidence as provenance and a digest and never as content, which is what makes
// a turn record safe to write to a stream; a recorder is an out-of-band observer of issuance instead, so
// nothing on that published path can reach one and no flagless run has one at all.
//
// Synchronous on purpose. Issuance is already serialized by the registry's actor, so a recorder called
// from inside it sees every issuance exactly once and in issuance order — a suspension point here would
// be the one thing that could let two of them swap places.
public protocol EvidenceContentRecorder: Sendable {

	func record(_ evidence: Evidence, content: String)
}
