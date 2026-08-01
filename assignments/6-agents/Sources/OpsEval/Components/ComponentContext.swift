import Foundation
import OpsCore

// The trusted contexts the component checks run under, and the run scope they carry. Transcribed from the
// Python evaluator's `_context`: the identifiers are the ones its observations name, and the default
// allowlist is the same six resources, so a check that widens its own reach has to change this constant
// rather than pass by accident.
enum ComponentContext {

	static let defaultAllowedResources = [
		"repository:logs/checkout.log",
		"repository:logs/maintenance.log",
		"repository:config/service.toml",
		"monitoring:error_rate",
		"monitoring:dead_end",
		"runbook:rb-checkout-5xx"
	]

	static func make(
		identity: String,
		thread: String,
		run: String,
		allowedResources: [String]? = nil
	) throws -> RuntimeContext {
		try RuntimeContext(
			identityID: identity,
			threadID: thread,
			runID: run,
			allowedResources: allowedResources ?? defaultAllowedResources
		)
	}

	// The scoped event view a thread's conversation state lives under. It stands in for the Python
	// evaluator's `checkpoint_key`: our loop has no checkpointer, and this is the one derivation that keys
	// per-thread state off the trusted triple rather than off anything a caller can name.
	static func eventViewScope(of context: RuntimeContext, secret: ScopeSecret) -> String {
		secret.opaqueScope(.eventView, identifiers: context.scopeIdentifiers)
	}
}
