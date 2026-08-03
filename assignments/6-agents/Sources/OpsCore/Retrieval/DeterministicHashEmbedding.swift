import CryptoKit
import Foundation

// Port of ops_scaffold.runbooks.DeterministicHashEmbeddings: small local lexical embeddings with no
// model download and no network access.
//
// Everything here stays in Double and keeps Python's operation order — accumulate signed unit
// contributions per bucket, sum the squares left to right, take one square root, divide each
// component once. The prepared fixture vectors are float64 and are re-derived and compared by strict
// equality, so any reassociation or early narrowing to Float would break the artifact contract.
// Narrowing happens at the CosineIndex boundary and nowhere else.
public struct DeterministicHashEmbedding: Hashable, Sendable {

	public static let name = "deterministic-hash-v1"
	public static let defaultDimensions = 256

	private static let dimensionBounds = 64...1_024

	public let dimensions: Int

	public init(dimensions: Int = Self.defaultDimensions) throws {
		guard Self.dimensionBounds.contains(dimensions) else {
			throw ContractError("embedding dimensions must be bounded")
		}

		self.dimensions = dimensions
	}

	public func embed(_ text: String) -> [Double] {
		var vector = [Double](repeating: 0, count: dimensions)
		for token in text.hashEmbeddingTokens {
			let digest = Array(SHA256.hash(data: Data(token.utf8)))
			let bucket = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
			vector[Int(bucket) % dimensions] += digest[4] & 1 == 1 ? 1 : -1
		}

		let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
		guard norm != 0 else { return vector }

		return vector.map { $0 / norm }
	}
}

// MARK: Tokenization

extension String {

	// Equivalent of re.findall(r"[a-z0-9]+(?:-[a-z0-9]+)*", text.casefold()) as a single scan: runs of
	// ASCII alphanumerics, joined by a hyphen only when a further run actually follows it. A hyphen
	// that leads, trails or doubles is a separator, exactly as the non-matching regex branch makes it.
	var hashEmbeddingTokens: [String] {
		var tokens: [String] = []
		var current = String.UnicodeScalarView()
		var pendingHyphen = false

		func flush() {
			if !current.isEmpty { tokens.append(String(current)) }
			current = String.UnicodeScalarView()
			pendingHyphen = false
		}

		for scalar in folding(options: [.caseInsensitive], locale: nil).unicodeScalars {
			if scalar.isHashEmbeddingTokenBody {
				if pendingHyphen {
					current.append("-")
					pendingHyphen = false
				}
				current.append(scalar)
			} else if scalar == "-", !current.isEmpty, !pendingHyphen {
				pendingHyphen = true
			} else {
				flush()
			}
		}
		flush()

		return tokens
	}
}

private extension Unicode.Scalar {

	var isHashEmbeddingTokenBody: Bool { ("a"..."z").contains(self) || ("0"..."9").contains(self) }
}
