extension Claude {

	public enum SessionError: Error {
		case deadlineExceeded(Duration)
		case turnFailed(message: String)
		case driverFailed(underlying: any Error)
		case toolProxyNotConfigured
	}

}
