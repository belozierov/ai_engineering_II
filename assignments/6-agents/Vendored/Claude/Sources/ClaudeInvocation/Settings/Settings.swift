import Foundation

public struct Settings: Sendable {

	public var hooks: [Hook.Event: [Hook]]
	public var permissions: Permissions
	// When `hooks` is empty, controls whether inherited hooks are silenced with `disableAllHooks: true`
	// (a controlled harness session) or left running (a user-facing session, where killing the user's own
	// configured hooks would be wrong). Only bites the empty case: a non-empty `hooks` set always renders
	// as `hooks`, never as `disableAllHooks`.
	public var disablesUnlistedHooks: Bool

	public init(hooks: [Hook.Event: [Hook]] = [:], permissions: Permissions = Permissions(), disablesUnlistedHooks: Bool = true) {
		self.hooks = hooks
		self.permissions = permissions
		self.disablesUnlistedHooks = disablesUnlistedHooks
	}

	public func makeJSON() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(self)
		return String(decoding: data, as: UTF8.self)
	}

	// One `--settings` total (a second flag deafens a PTY-driven child — measured): the typed
	// settings overlay a raw base payload (a replayed launch's `--settings`). Module-owned keys
	// win; the base's other keys ride verbatim. The base's hook state — `hooks` AND
	// `disableAllHooks`, the two mutually exclusive shapes this type itself renders — is
	// dropped whole, not merged: hook definitions are harness plumbing measured
	// prefix-invisible, replaying another harness's fifo bridge is cross-talk, and a
	// surviving base `disableAllHooks: true` next to the typed hooks would deafen the very
	// fifo bridge the child is driven through.
	public func makeJSON(over base: String?) throws -> String {
		guard let base else { return try makeJSON() }
		guard let object = try? JSONSerialization.jsonObject(with: Data(base.utf8)),
			let dictionary = object as? [String: Any] else {
			throw Errors.malformedBase(base)
		}

		let hookState: Set<String> = ["hooks", "disableAllHooks"]
		var merged = dictionary.filter { !hookState.contains($0.key) }
		guard !merged.isEmpty else { return try makeJSON() }

		let typed = try JSONSerialization.jsonObject(with: Data(try makeJSON().utf8)) as? [String: Any] ?? [:]
		merged.merge(typed) { _, typed in typed }
		let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
		return String(decoding: data, as: UTF8.self)
	}

	public enum Errors: Error, Equatable {
		case malformedBase(String)
	}

}

// MARK: Permissions

extension Settings {

	public struct Permissions: Sendable, Encodable {

		public var allow: [String]
		public var deny: [String]

		public init(allow: [String] = [], deny: [String] = []) {
			self.allow = allow
			self.deny = deny
		}

		var isEmpty: Bool { allow.isEmpty && deny.isEmpty }

	}

}

// MARK: Encodable

extension Settings: Encodable {

	private enum CodingKeys: String, CodingKey {
		case disableAllHooks
		case hooks
		case permissions
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		if hooks.isEmpty {
			if disablesUnlistedHooks {
				try container.encode(true, forKey: .disableAllHooks)
			}
		} else {
			try container.encode(hooks, forKey: .hooks)
		}

		if !permissions.isEmpty {
			try container.encode(permissions, forKey: .permissions)
		}
	}

}
