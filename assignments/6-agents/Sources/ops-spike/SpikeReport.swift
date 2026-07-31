struct SpikeReport {

	struct Criterion {

		let title: String
		let isPassing: Bool
		let detail: String

	}

	var criteria: [Criterion] = []
	var notes: [String] = []

	mutating func record(_ title: String, isPassing: Bool, detail: String) {
		criteria.append(Criterion(title: title, isPassing: isPassing, detail: detail))
	}

	var isPassing: Bool { !criteria.isEmpty && criteria.allSatisfy(\.isPassing) }

	var rendered: String {
		var lines = ["", "=== ops-spike summary ==="]

		for (index, criterion) in criteria.enumerated() {
			let verdict = criterion.isPassing ? "PASS" : "FAIL"
			lines.append("\(verdict)  \(index + 1). \(criterion.title) — \(criterion.detail)")
		}

		lines += ["", "--- context ---"] + notes
		lines.append("")
		lines.append(isPassing ? "ops-spike: all criteria PASS" : "ops-spike: FAILED")

		return lines.joined(separator: "\n")
	}

}

extension String {

	// Live payloads are multi-paragraph; a summary line needs one readable slice of them.
	func excerpt(limit: Int = 160) -> String {
		let flattened = split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
		guard flattened.count > limit else { return flattened.isEmpty ? "<empty>" : flattened }

		return flattened.prefix(limit) + "…"
	}

}
