extension Settings {

	init(configuration: Claude.SessionConfiguration) {
		// Allow rules have no effect when checks are bypassed; deny rules apply in every mode.
		// Hosted tools are allowed automatically — declaring a tool in the configuration is the permission decision.
		let permissions = configuration.permissions
		let hostedToolRules = configuration.hostedTools.map { Claude.Permissions.Rule.hostedTool(named: $0.name) }
		self.init(
			permissions: Permissions(
				allow: permissions.isBypassingChecks ? [] : (permissions.allow + hostedToolRules).map(\.rawValue),
				deny: permissions.deny.map(\.rawValue)))
	}

}
