import ClaudeDomain

extension Settings {

	public init(configuration: Claude.SessionConfiguration) {
		var hooks = [Hook.Event: [Hook]]()
		for hook in configuration.hooks {
			hooks[Hook.Event(hook.event), default: []].append(Hook(hook))
		}

		// Allow rules have no effect when checks are bypassed; deny rules apply in every mode.
		// Hosted tools are allowed automatically — declaring a tool in the configuration is the permission decision.
		let permissions = configuration.permissions
		let hostedToolRules = configuration.hostedTools.map { Claude.Permissions.Rule.hostedTool(named: $0.name) }
		self.init(
			hooks: hooks,
			permissions: Permissions(
				allow: permissions.isBypassingChecks ? [] : (permissions.allow + hostedToolRules).map(\.rawValue),
				deny: permissions.deny.map(\.rawValue)))
	}

}

// MARK: Hooks

extension Settings.Hook {

	init(_ hook: Claude.Hook) {
		switch hook.action {
		case .command(let command):
			self.init(matcher: hook.matcher, command: command)
		}
	}

}

extension Settings.Hook.Event {

	init(_ event: Claude.Hook.Event) {
		self = switch event {
		case .preToolUse: .preToolUse
		case .postToolUse: .postToolUse
		}
	}

}
