import Foundation
import OpsCore

// Strict JSON value tree, because the prepared-artifact contract needs two things Foundation's
// decoder does not give:
//
//   - duplicate object fields are a hard error rather than last-write-wins, so a tampered artifact
//     cannot smuggle a second `logical_digest` past the validator, and
//   - the integer/real distinction survives parsing, so canonicalJSON can reproduce Python's
//     json.dumps(ensure_ascii=True, sort_keys=True, separators=(",", ":")) byte for byte and the
//     prepared logical digests can be recomputed here.
//
// It is deliberately not Codable: the point is to compare and re-serialize raw shapes, not to map
// them onto Swift types before they have been validated.
public enum RunbookJSON: Hashable, Sendable {

	case null
	case bool(Bool)
	case integer(Int)
	case double(Double)
	case string(String)
	case array([RunbookJSON])
	case object([String: RunbookJSON])

	public var boolValue: Bool? {
		guard case let .bool(value) = self else { return nil }

		return value
	}

	public var integerValue: Int? {
		guard case let .integer(value) = self else { return nil }

		return value
	}

	// Mirror of Python's `type(value) in {int, float}`: a JSON integer is a perfectly good number
	// wherever the contract asks for one.
	public var numberValue: Double? {
		switch self {
		case let .integer(value): Double(value)

		case let .double(value): value

		case .null, .bool, .string, .array, .object: nil
		}
	}

	public var stringValue: String? {
		guard case let .string(value) = self else { return nil }

		return value
	}

	public var arrayValue: [RunbookJSON]? {
		guard case let .array(value) = self else { return nil }

		return value
	}

	public var objectValue: [String: RunbookJSON]? {
		guard case let .object(value) = self else { return nil }

		return value
	}
}

// MARK: Canonical form

public extension RunbookJSON {

	// json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).
	var canonicalJSON: String {
		var output = ""
		append(to: &output)

		return output
	}

	// The prepared artifacts identify their own logical content by this digest, which follows the same
	// SHA-256-over-raw-UTF-8 convention as every content digest in the system.
	var logicalDigest: String { SourceResult.contentDigest(of: canonicalJSON) }

	private func append(to output: inout String) {
		switch self {
		case .null:
			output += "null"

		case let .bool(value):
			output += value ? "true" : "false"

		case let .integer(value):
			output += String(value)

		case let .double(value):
			// Swift's shortest round-tripping description agrees with Python's float repr across the
			// whole range the contract admits: finite and |x| <= 1, so never Python's exponent form.
			output += value.description

		case let .string(value):
			Self.appendEscaped(value, to: &output)

		case let .array(values):
			output += "["
			for (offset, value) in values.enumerated() {
				if offset > 0 { output += "," }
				value.append(to: &output)
			}
			output += "]"

		case let .object(fields):
			output += "{"
			for (offset, field) in Self.sortedByCodePoint(fields).enumerated() {
				if offset > 0 { output += "," }
				Self.appendEscaped(field.key, to: &output)
				output += ":"
				field.value.append(to: &output)
			}
			output += "}"
		}
	}

	// sort_keys=True orders by code point, which is what Python's str comparison does and what Swift's
	// own String ordering deliberately does not.
	private static func sortedByCodePoint(_ fields: [String: RunbookJSON]) -> [(key: String, value: RunbookJSON)] {
		fields.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) { $0.value < $1.value } }
	}

	// ensure_ascii=True: everything outside printable ASCII leaves as a \uXXXX escape, with astral
	// scalars split into a surrogate pair the way Python's encoder does.
	private static func appendEscaped(_ value: String, to output: inout String) {
		output += "\""
		for scalar in value.unicodeScalars {
			switch scalar {
			case "\"": output += "\\\""

			case "\\": output += "\\\\"

			case "\n": output += "\\n"

			case "\r": output += "\\r"

			case "\t": output += "\\t"

			case "\u{08}": output += "\\b"

			case "\u{0c}": output += "\\f"

			default:
				if (" "..."~").contains(scalar) {
					output.unicodeScalars.append(scalar)
				} else if let unit = UInt16(exactly: scalar.value) {
					output += Self.escape(unit)
				} else {
					let offset = scalar.value - 0x1_0000
					output += Self.escape(UInt16(0xd800 + (offset >> 10)))
					output += Self.escape(UInt16(0xdc00 + (offset & 0x3ff)))
				}
			}
		}
		output += "\""
	}

	private static func escape(_ unit: UInt16) -> String {
		var digits = ""
		for shift in stride(from: 12, through: 0, by: -4) {
			digits.append(Self.hexadecimalDigits[Int((unit >> UInt16(shift)) & 0x0f)])
		}

		return "\\u\(digits)"
	}

	private static let hexadecimalDigits = Array("0123456789abcdef")
}

// MARK: Parsing

public extension RunbookJSON {

	struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {

		public let description: String

		public init(_ description: String) {
			self.description = String(description.prefix(160))
		}
	}

	static func parse(_ data: Data) throws -> RunbookJSON {
		// Whole-document UTF-8 validation first, exactly where Python's raw.decode("utf-8") sits, so
		// the parser below can treat every literal string byte as part of a valid sequence.
		guard let text = String(data: data, encoding: .utf8) else { throw ParseError("JSON is not valid UTF-8") }

		var parser = Parser(bytes: Array(text.utf8))
		let value = try parser.parseValue(depth: 0)
		try parser.finish()

		return value
	}

	// Hand-written on purpose. Beyond duplicate-field rejection and the number-kind distinction, this
	// also refuses the JSON extensions Python's loader accepts by default and the scaffold rejects
	// through parse_constant: NaN, Infinity and -Infinity are simply not grammar here.
	private struct Parser {

		private static let maximumDepth = 64

		let bytes: [UInt8]

		private var offset = 0

		init(bytes: [UInt8]) {
			self.bytes = bytes
		}

		mutating func parseValue(depth: Int) throws -> RunbookJSON {
			guard depth <= Self.maximumDepth else { throw ParseError("JSON nesting is too deep") }

			skipWhitespace()
			switch try peek() {
			case UInt8(ascii: "{"): return try parseObject(depth: depth)

			case UInt8(ascii: "["): return try parseArray(depth: depth)

			case UInt8(ascii: "\""): return .string(try parseString())

			case UInt8(ascii: "t"): return try consume(literal: "true", as: .bool(true))

			case UInt8(ascii: "f"): return try consume(literal: "false", as: .bool(false))

			case UInt8(ascii: "n"): return try consume(literal: "null", as: .null)

			default: return try parseNumber()
			}
		}

		mutating func finish() throws {
			skipWhitespace()
			guard offset == bytes.count else { throw ParseError("JSON has trailing content") }
		}

		// MARK: Composites

		private mutating func parseObject(depth: Int) throws -> RunbookJSON {
			offset += 1
			var fields: [String: RunbookJSON] = [:]
			skipWhitespace()
			if try peek() == UInt8(ascii: "}") {
				offset += 1

				return .object(fields)
			}

			while true {
				skipWhitespace()
				let key = try parseString()
				guard fields[key] == nil else { throw ParseError("JSON object has a duplicate field") }

				skipWhitespace()
				try expect(UInt8(ascii: ":"))
				fields[key] = try parseValue(depth: depth + 1)

				skipWhitespace()
				let separator = try peek()
				offset += 1
				if separator == UInt8(ascii: "}") { return .object(fields) }
				guard separator == UInt8(ascii: ",") else { throw ParseError("JSON object is malformed") }
			}
		}

		private mutating func parseArray(depth: Int) throws -> RunbookJSON {
			offset += 1
			var values: [RunbookJSON] = []
			skipWhitespace()
			if try peek() == UInt8(ascii: "]") {
				offset += 1

				return .array(values)
			}

			while true {
				values.append(try parseValue(depth: depth + 1))

				skipWhitespace()
				let separator = try peek()
				offset += 1
				if separator == UInt8(ascii: "]") { return .array(values) }
				guard separator == UInt8(ascii: ",") else { throw ParseError("JSON array is malformed") }
			}
		}

		// MARK: Scalars

		private mutating func parseString() throws -> String {
			try expect(UInt8(ascii: "\""))
			var utf8: [UInt8] = []

			while true {
				let byte = try peek()
				offset += 1
				switch byte {
				case UInt8(ascii: "\""):
					guard let value = String(bytes: utf8, encoding: .utf8) else {
						throw ParseError("JSON string is not valid text")
					}

					return value

				case UInt8(ascii: "\\"):
					try appendEscape(to: &utf8)

				case 0x00...0x1f:
					throw ParseError("JSON string contains a control character")

				default:
					utf8.append(byte)
				}
			}
		}

		private mutating func appendEscape(to utf8: inout [UInt8]) throws {
			let byte = try peek()
			offset += 1
			switch byte {
			case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(byte)

			case UInt8(ascii: "b"): utf8.append(0x08)

			case UInt8(ascii: "f"): utf8.append(0x0c)

			case UInt8(ascii: "n"): utf8.append(0x0a)

			case UInt8(ascii: "r"): utf8.append(0x0d)

			case UInt8(ascii: "t"): utf8.append(0x09)

			case UInt8(ascii: "u"): utf8.append(contentsOf: String(try parseEscapedScalar()).utf8)

			default: throw ParseError("JSON string has an unsupported escape")
			}
		}

		// Python's loader tolerates a lone surrogate in a decoded string; a Swift String cannot hold
		// one, so an unpaired escape is refused here instead. Strictly narrower, and the prepared
		// artifacts are ASCII throughout.
		private mutating func parseEscapedScalar() throws -> Unicode.Scalar {
			let high = try parseHexadecimalUnit()
			if !(0xd800...0xdfff).contains(high), let scalar = Unicode.Scalar(high) { return scalar }

			guard (0xd800...0xdbff).contains(high) else { throw ParseError("JSON escape is an unpaired surrogate") }

			try expect(UInt8(ascii: "\\"))
			try expect(UInt8(ascii: "u"))
			let low = try parseHexadecimalUnit()
			guard (0xdc00...0xdfff).contains(low),
				let scalar = Unicode.Scalar(0x1_0000 + (UInt32(high - 0xd800) << 10) + UInt32(low - 0xdc00)) else {
				throw ParseError("JSON escape is an unpaired surrogate")
			}

			return scalar
		}

		private mutating func parseHexadecimalUnit() throws -> UInt16 {
			var unit: UInt16 = 0
			for _ in 0..<4 {
				let byte = try peek()
				offset += 1
				guard let digit = byte.hexadecimalDigitValue else { throw ParseError("JSON escape is malformed") }

				unit = unit << 4 | UInt16(digit)
			}

			return unit
		}

		// The JSON number grammar exactly: an optional minus, no leading zeros, no bare leading or
		// trailing decimal point, and a digit-bearing exponent. A lexeme with neither a fraction nor an
		// exponent is a Python int, and the two serialize differently.
		private mutating func parseNumber() throws -> RunbookJSON {
			let start = offset
			if try peek() == UInt8(ascii: "-") { offset += 1 }
			try scanIntegerPart()

			var isReal = false
			if offset < bytes.count, bytes[offset] == UInt8(ascii: ".") {
				isReal = true
				offset += 1
				try scanDigits()
			}
			if offset < bytes.count, bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
				isReal = true
				offset += 1
				if offset < bytes.count, bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") {
					offset += 1
				}
				try scanDigits()
			}

			let lexeme = String(decoding: bytes[start..<offset], as: UTF8.self)
			guard isReal else {
				// Python integers are unbounded; a value this port cannot hold exactly is refused
				// rather than silently widened to a Double, which would change its canonical form.
				guard let value = Int(lexeme) else { throw ParseError("JSON integer is out of range") }

				return .integer(value)
			}
			guard let value = Double(lexeme), value.isFinite else {
				throw ParseError("JSON number is not representable")
			}

			return .double(value)
		}

		private mutating func scanIntegerPart() throws {
			guard let byte = try? peek() else { throw ParseError("JSON number is truncated") }

			guard byte != UInt8(ascii: "0") else {
				offset += 1
				if offset < bytes.count, bytes[offset].isASCIIDigit {
					throw ParseError("JSON number has a leading zero")
				}

				return
			}

			try scanDigits()
		}

		private mutating func scanDigits() throws {
			let start = offset
			while offset < bytes.count, bytes[offset].isASCIIDigit { offset += 1 }
			guard offset > start else { throw ParseError("JSON number is malformed") }
		}

		// MARK: Cursor

		private mutating func consume(literal: String, as value: RunbookJSON) throws -> RunbookJSON {
			for byte in literal.utf8 {
				try expect(byte)
			}

			return value
		}

		private mutating func expect(_ byte: UInt8) throws {
			guard try peek() == byte else { throw ParseError("JSON is malformed") }

			offset += 1
		}

		private func peek() throws -> UInt8 {
			guard offset < bytes.count else { throw ParseError("JSON ended unexpectedly") }

			return bytes[offset]
		}

		private mutating func skipWhitespace() {
			while offset < bytes.count, bytes[offset].isJSONWhitespace { offset += 1 }
		}
	}
}

private extension UInt8 {

	var isASCIIDigit: Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) }

	var isJSONWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0a || self == 0x0d }

	var hexadecimalDigitValue: UInt8? {
		switch self {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): self - UInt8(ascii: "0")

		case UInt8(ascii: "a")...UInt8(ascii: "f"): self - UInt8(ascii: "a") + 10

		case UInt8(ascii: "A")...UInt8(ascii: "F"): self - UInt8(ascii: "A") + 10

		default: nil
		}
	}
}
