import Foundation

public extension Sequence<UInt8> {

	var hexadecimalString: String {
		reduce(into: "") { result, byte in
			result.append(HexadecimalDigits.characters[Int(byte >> 4)])
			result.append(HexadecimalDigits.characters[Int(byte & 0x0f)])
		}
	}
}

private enum HexadecimalDigits {

	static let characters = Array("0123456789abcdef")
}
