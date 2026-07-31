extension Claude {

	public enum Feature: CaseIterable, Sendable {
		case promptCaching
		case autoCompaction
		case projectInstructions
		case autoMemory
		case gitInstructions
		case backgroundTasks
		case toolSearch
		case telemetry
		case errorReporting
		case autoUpdates
		case installationChecks
		case ideAutoConnect
		case nonessentialTraffic
		case awaySummary
		case slashCommands
		case externalMCPServers
		case chromeIntegration
		case inheritedSettings
	}

	public typealias Features = Set<Feature>

}

extension Claude.Features {

	public static var `default`: Claude.Features { Set(Claude.Feature.allCases) }

}
