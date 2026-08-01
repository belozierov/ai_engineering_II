import Foundation

struct Settings: Sendable {

	var permissions: Permissions

	init(permissions: Permissions = Permissions()) {
		self.permissions = permissions
	}

	func makeJSON() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(self)
		return String(decoding: data, as: UTF8.self)
	}

}

// MARK: Permissions

extension Settings {

	struct Permissions: Sendable, Encodable {

		var allow: [String]
		var deny: [String]

		init(allow: [String] = [], deny: [String] = []) {
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
		case permissions
	}

	func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		// Every session this type renders is a controlled harness session, so the machine's inherited
		// hooks are always silenced — nothing here declares hooks of its own for them to collide with.
		try container.encode(true, forKey: .disableAllHooks)

		if !permissions.isEmpty {
			try container.encode(permissions, forKey: .permissions)
		}
	}

}
