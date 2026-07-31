import Foundation

public enum RuntimeChannel: String, CaseIterable, Codable, Sendable {

	case cli
	case chainlit
	case evaluator
}

// Trusted runner context. Model or user input must never reach these fields directly: every scope in
// the system is derived from them, so a forged identity here would cross evidence and memory scopes.
public struct RuntimeContext: Hashable, Sendable {

	public let identityID: String
	public let threadID: String
	public let runID: String
	public let channel: RuntimeChannel
	public let allowedResources: [String]?

	public init(
		identityID: String,
		threadID: String,
		runID: String,
		channel: RuntimeChannel = .evaluator,
		allowedResources: [String]? = nil
	) throws {
		self.identityID = try identityID.validatedIdentifier("runtime identity")
		self.threadID = try threadID.validatedIdentifier("runtime thread")
		self.runID = try runID.validatedIdentifier("runtime run")
		self.channel = channel
		self.allowedResources = try allowedResources?.validatedResources("runtime resource scope")
	}

	// The framed identifier triple every scope derivation in the system agrees on; nil
	// allowedResources means unrestricted and deliberately takes no part in scoping.
	public var scopeIdentifiers: [String] { [identityID, threadID, runID] }
}
