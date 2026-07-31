import ClaudeDomain
import Foundation

// One model the loop can talk to: the transport that carries the call and the model that answers it, kept
// together because neither is useful alone and because both halves are the A/B knob — a scenario failing on
// haiku is re-run on sonnet through the same transport to tell model noise from a bug.
public struct ModelEndpoint: Sendable {

	public let transport: any ModelTransport
	public let model: Claude.Model

	public init(transport: any ModelTransport, model: Claude.Model = .haiku) {
		self.transport = transport
		self.model = model
	}
}
