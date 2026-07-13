// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public enum SessionError: Error {
		case deadlineExceeded(Duration)
		case turnFailed(message: String)
		case driverFailed(underlying: any Error)
		case toolProxyNotConfigured
	}

}
