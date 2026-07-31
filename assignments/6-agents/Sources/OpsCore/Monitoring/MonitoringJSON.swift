import Foundation

// The monitoring boundary parses wire bytes itself instead of through JSONSerialization, because the
// contract rejects what a lenient parser accepts — duplicate object keys, non-finite numbers,
// unbounded nesting — and because the content digest is taken over a canonical re-encoding, which
// needs integers and doubles kept apart.
public enum MonitoringJSON: Hashable, Sendable {

	case null
	case bool(Bool)
	case integer(Int)
	case number(Double)
	case string(String)
	case array([MonitoringJSON])
	case object([String: MonitoringJSON])

	public struct Limits: Hashable, Sendable {

		// What an allowlisted monitoring response is allowed to be. A response outside these bounds is
		// not a big response, it is a response from something that is no longer the fixture.
		public static let contract = Limits()

		// The fixture is trusted local data rather than a wire payload, so it is bounded by file size
		// and shape only.
		public static let fixture = Limits(depth: 20, valueCount: 10_000)

		public let depth: Int
		public let valueCount: Int
		public let keyLength: Int
		public let stringLength: Int
		public let arrayCount: Int
		public let magnitude: Double

		public init(
			depth: Int = 10,
			valueCount: Int = 1_000,
			keyLength: Int = 100,
			stringLength: Int = 2_000,
			arrayCount: Int = 100,
			magnitude: Double = 1_000_000_000_000
		) {
			self.depth = depth
			self.valueCount = valueCount
			self.keyLength = keyLength
			self.stringLength = stringLength
			self.arrayCount = arrayCount
			self.magnitude = magnitude
		}
	}

	public static func parse(_ bytes: some Sequence<UInt8>, limits: Limits = .contract) throws -> MonitoringJSON {
		var reader = Reader(bytes: Array(bytes), limits: limits)
		let value = try reader.value(depth: 1)
		try reader.expectEnd()

		return value
	}

	public var fields: [String: MonitoringJSON]? {
		guard case let .object(fields) = self else { return nil }

		return fields
	}

	public var text: String? {
		guard case let .string(value) = self else { return nil }

		return value
	}

	public var numeric: Double? {
		switch self {
		case let .integer(value): Double(value)

		case let .number(value): value

		case .null, .bool, .string, .array, .object: nil
		}
	}

	// Sorted keys, no whitespace, every non-printable-ASCII scalar escaped: the same value always
	// serializes to the same bytes, which is what makes a content digest a stable identity.
	public var canonicalJSON: String {
		var output = ""
		append(to: &output)

		return output
	}

	private func append(to output: inout String) {
		switch self {
		case .null:
			output += "null"

		case let .bool(value):
			output += value ? "true" : "false"

		case let .integer(value):
			output += String(value)

		case let .number(value):
			output += String(value)

		case let .string(value):
			Self.append(text: value, to: &output)

		case let .array(values):
			output += "["
			for (offset, value) in values.enumerated() {
				if offset > 0 { output += "," }
				value.append(to: &output)
			}
			output += "]"

		case let .object(fields):
			output += "{"
			for (offset, key) in fields.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }).enumerated() {
				if offset > 0 { output += "," }
				Self.append(text: key, to: &output)
				output += ":"
				fields[key]?.append(to: &output)
			}
			output += "}"
		}
	}

	private static func append(text: String, to output: inout String) {
		output += "\""
		for scalar in text.unicodeScalars {
			switch scalar {
			case "\"": output += "\\\""

			case "\\": output += "\\\\"

			case "\n": output += "\\n"

			case "\r": output += "\\r"

			case "\t": output += "\\t"

			case "\u{08}": output += "\\b"

			case "\u{0c}": output += "\\f"

			default:
				guard scalar.value < 0x20 || scalar.value > 0x7e else {
					output.unicodeScalars.append(scalar)
					continue
				}
				output += Self.escaped(scalar)
			}
		}
		output += "\""
	}

	private static func escaped(_ scalar: Unicode.Scalar) -> String {
		guard scalar.value > 0xffff else { return String(format: "\\u%04x", scalar.value) }

		let offset = scalar.value - 0x1_0000

		return String(format: "\\u%04x\\u%04x", 0xd800 + (offset >> 10), 0xdc00 + (offset & 0x3ff))
	}
}

// MARK: Reader

private extension MonitoringJSON {

	struct Reader {

		let bytes: [UInt8]
		let limits: Limits

		var index = 0
		var valueCount = 0

		mutating func value(depth: Int) throws -> MonitoringJSON {
			guard depth <= limits.depth else { throw ContractError("monitoring JSON exceeds the nesting limit") }
			valueCount += 1
			guard valueCount <= limits.valueCount else { throw ContractError("monitoring JSON exceeds the value limit") }

			skipWhitespace()

			return switch try peek() {
			case UInt8(ascii: "{"): try object(depth: depth)

			case UInt8(ascii: "["): try array(depth: depth)

			case UInt8(ascii: "\""): .string(try text(maximum: limits.stringLength))

			case UInt8(ascii: "t"): try literal("true", value: .bool(true))

			case UInt8(ascii: "f"): try literal("false", value: .bool(false))

			case UInt8(ascii: "n"): try literal("null", value: .null)

			default: try number()
			}
		}

		mutating func expectEnd() throws {
			skipWhitespace()
			guard index == bytes.count else { throw ContractError("monitoring JSON carries trailing bytes") }
		}

		// MARK: Composites

		private mutating func object(depth: Int) throws -> MonitoringJSON {
			index += 1
			var fields: [String: MonitoringJSON] = [:]
			skipWhitespace()
			guard try peek() != UInt8(ascii: "}") else {
				index += 1

				return .object(fields)
			}

			while true {
				skipWhitespace()
				guard try peek() == UInt8(ascii: "\"") else { throw ContractError("monitoring JSON object key is malformed") }
				let key = try text(maximum: limits.keyLength)
				skipWhitespace()
				try expect(UInt8(ascii: ":"))
				guard fields.updateValue(try value(depth: depth + 1), forKey: key) == nil else {
					throw ContractError("monitoring JSON repeats an object key")
				}
				skipWhitespace()
				guard try peek() == UInt8(ascii: ",") else { break }
				index += 1
			}
			try expect(UInt8(ascii: "}"))

			return .object(fields)
		}

		private mutating func array(depth: Int) throws -> MonitoringJSON {
			index += 1
			var values: [MonitoringJSON] = []
			skipWhitespace()
			guard try peek() != UInt8(ascii: "]") else {
				index += 1

				return .array(values)
			}

			while true {
				values.append(try value(depth: depth + 1))
				guard values.count <= limits.arrayCount else { throw ContractError("monitoring JSON exceeds the array limit") }
				skipWhitespace()
				guard try peek() == UInt8(ascii: ",") else { break }
				index += 1
			}
			try expect(UInt8(ascii: "]"))

			return .array(values)
		}

		// MARK: Scalars

		private mutating func text(maximum: Int) throws -> String {
			try expect(UInt8(ascii: "\""))
			var decoded: [UInt8] = []
			while true {
				let byte = try next()
				if byte == UInt8(ascii: "\"") { break }
				guard byte >= 0x20 else { throw ContractError("monitoring JSON string carries a control byte") }
				guard byte == UInt8(ascii: "\\") else {
					decoded.append(byte)
					continue
				}
				decoded.append(contentsOf: try escape())
			}
			guard let value = String(bytes: decoded, encoding: .utf8), value.unicodeScalars.count <= maximum,
				!value.unicodeScalars.contains("\0") else {
				throw ContractError("monitoring JSON string is invalid or unbounded")
			}

			return value
		}

		private mutating func escape() throws -> [UInt8] {
			switch try next() {
			case UInt8(ascii: "\""): [UInt8(ascii: "\"")]

			case UInt8(ascii: "\\"): [UInt8(ascii: "\\")]

			case UInt8(ascii: "/"): [UInt8(ascii: "/")]

			case UInt8(ascii: "b"): [0x08]

			case UInt8(ascii: "f"): [0x0c]

			case UInt8(ascii: "n"): [0x0a]

			case UInt8(ascii: "r"): [0x0d]

			case UInt8(ascii: "t"): [0x09]

			case UInt8(ascii: "u"): Array(String(try unicodeEscape()).utf8)

			default: throw ContractError("monitoring JSON string escape is unsupported")
			}
		}

		private mutating func unicodeEscape() throws -> Unicode.Scalar {
			let leading = try hexadecimalQuad()
			guard (0xd800...0xdbff).contains(leading) else {
				guard let scalar = Unicode.Scalar(leading), !(0xdc00...0xdfff).contains(leading) else {
					throw ContractError("monitoring JSON string escape is unsupported")
				}

				return scalar
			}
			try expect(UInt8(ascii: "\\"))
			try expect(UInt8(ascii: "u"))
			let trailing = try hexadecimalQuad()
			guard (0xdc00...0xdfff).contains(trailing),
				let scalar = Unicode.Scalar(0x1_0000 + ((leading - 0xd800) << 10) + (trailing - 0xdc00)) else {
				throw ContractError("monitoring JSON string escape is unsupported")
			}

			return scalar
		}

		private mutating func hexadecimalQuad() throws -> UInt32 {
			var value: UInt32 = 0
			for _ in 0..<4 {
				let byte = try next()
				guard let digit = Self.hexadecimalValue(byte) else {
					throw ContractError("monitoring JSON string escape is unsupported")
				}
				value = value << 4 | digit
			}

			return value
		}

		private mutating func literal(_ token: String, value: MonitoringJSON) throws -> MonitoringJSON {
			for byte in token.utf8 { try expect(byte) }

			return value
		}

		private mutating func number() throws -> MonitoringJSON {
			let start = index
			if try peek() == UInt8(ascii: "-") { index += 1 }
			var isInteger = true
			try integerPart()
			if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
				isInteger = false
				index += 1
				try fractionDigits()
			}
			if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
				isInteger = false
				index += 1
				if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
				try fractionDigits()
			}
			let token = String(decoding: bytes[start..<index], as: UTF8.self)
			if isInteger, let value = Int(token) {
				guard Double(value.magnitude) <= limits.magnitude else { throw ContractError("monitoring JSON number is out of range") }

				return .integer(value)
			}
			guard let value = Double(token), value.isFinite, value.magnitude <= limits.magnitude else {
				throw ContractError("monitoring JSON number is out of range")
			}

			return .number(value)
		}

		private mutating func integerPart() throws {
			let byte = try next()
			guard Self.isDigit(byte) else { throw ContractError("monitoring JSON number is malformed") }
			guard byte != UInt8(ascii: "0") else {
				guard index == bytes.count || !Self.isDigit(bytes[index]) else {
					throw ContractError("monitoring JSON number is malformed")
				}

				return
			}
			while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
		}

		private mutating func fractionDigits() throws {
			let start = index
			while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
			guard index > start else { throw ContractError("monitoring JSON number is malformed") }
		}

		// MARK: Cursor

		private mutating func skipWhitespace() {
			while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0a || bytes[index] == 0x0d {
				index += 1
			}
		}

		private func peek() throws -> UInt8 {
			guard index < bytes.count else { throw ContractError("monitoring JSON ends early") }

			return bytes[index]
		}

		private mutating func next() throws -> UInt8 {
			let byte = try peek()
			index += 1

			return byte
		}

		private mutating func expect(_ byte: UInt8) throws {
			guard try next() == byte else { throw ContractError("monitoring JSON is malformed") }
		}

		private static func isDigit(_ byte: UInt8) -> Bool {
			UInt8(ascii: "0")...UInt8(ascii: "9") ~= byte
		}

		private static func hexadecimalValue(_ byte: UInt8) -> UInt32? {
			switch byte {
			case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))

			case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a")) + 10

			case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A")) + 10

			default: nil
			}
		}
	}
}
