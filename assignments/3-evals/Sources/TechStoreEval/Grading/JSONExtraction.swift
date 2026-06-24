import Foundation

extension String {

    // The CLI has no response_format mode, so a judge may wrap its JSON in ``` fences or prose.
    // Slice from the first opening bracket to the last matching closer.
    func extractedJSON() -> String {
        let unfenced = strippingCodeFence().trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = unfenced.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return unfenced }

        let closer: Character = unfenced[start] == "{" ? "}" : "]"
        guard let end = unfenced.lastIndex(of: closer) else { return unfenced }

        return String(unfenced[start...end])
    }

    private func strippingCodeFence() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

}
