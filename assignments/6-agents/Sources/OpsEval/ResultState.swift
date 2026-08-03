import Foundation

// The closed states shared by core and live evaluator rows. UNAVAILABLE says the evaluator could not
// reach the observation at all, which is a different fact from FAIL — the Capability Ledger is the one
// place that collapses the two, because a capability nobody could observe is not a capability shown.
public enum ResultState: String, CaseIterable, Codable, Sendable {

	case pass = "PASS"
	case fail = "FAIL"
	case skip = "SKIP"
	case unavailable = "UNAVAILABLE"
}
