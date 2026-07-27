import Foundation
import RAGCore

// TODO 5 — faithfulness validator (the non-gameable version). A cited `[Source: X]`
// must be among the titles actually retrieved, so appending a citation to a
// hallucination no longer passes.
public enum Validation {

    private static let refusalMarkers = [
        "don't have enough", "do not have enough", "no information", "cannot answer", "not found in"
    ]

    // Verifies the answer is grounded in what was retrieved:
    //   - a refusal passes without any citation;
    //   - a non-refusal answer must carry at least one [Source: Title] citation;
    //   - every cited title must be among `retrievedTitles` (case-insensitive, trimmed).
    // On failure throws a FaithfulnessError whose message doubles as the regenerate
    // instruction. On success returns `output` unchanged.
    public static func checkFaithfulness(_ output: String, retrievedTitles: [String]) throws -> String {
        let citedTitles = citedTitles(in: output)

        // A plain refusal (marker, no citation) legitimately grounds nothing, so it passes. But a
        // refusal marker sitting alongside citations means the answer still makes cited claims —
        // don't short-circuit; fall through to citation validation so a fake source still fails.
        if isRefusal(output) && citedTitles.isEmpty { return output }

        guard !citedTitles.isEmpty else {
            throw FaithfulnessError(
                "Your answer cites no sources. Cite every claim with [Source: Title] using only the "
                + "retrieved article titles, or say you don't have enough information."
            )
        }

        let allowed = Set(retrievedTitles.map(normalize))
        for title in citedTitles where !allowed.contains(normalize(title)) {
            throw FaithfulnessError(
                "You cited [Source: \(title)], which is not among the retrieved articles "
                + "(\(retrievedTitles.joined(separator: ", "))). Cite only retrieved sources and regenerate your answer."
            )
        }

        return output
    }

    // MARK: Tier 2 — LLM-as-judge

    // The outcome of a judge grade. A failing grade is thrown as a FaithfulnessError instead
    // (mirroring Tier 1), so this type only distinguishes a genuine pass from a pass forced by
    // unparseable judge output — letting the caller warn without blocking the chat.
    public enum JudgeVerdict: Sendable {

        case pass
        case unparseable(String)
    }

    // Bonus (Tier 2): grade whether every factual claim in `answer` is supported by `context`, claim
    // by claim. Tier 1 checks that citations point at retrieved titles; this catches the subtler case
    // where the citation is valid but the sentence over-claims beyond what the source actually says.
    //
    // A pure no-evidence refusal short-circuits to `.pass` (nothing to ground): a refusal marker, no
    // citation, AND empty context — the gate=none path, where the retrieval state box cleared both the
    // titles and the packed context. When context is non-empty, evidence existed, so a refusal-worded
    // answer that still smuggles in content ("...but the winner was X") IS judged and can fail here.
    // An unsupported or contradicted claim throws a FaithfulnessError naming it, consistent with Tier
    // 1's regenerate instruction. The judge is only advisory infrastructure, so unparseable output is
    // treated as a pass and surfaced as `.unparseable` for the caller to warn about — a flaky judge
    // must never brick the chat.
    public static func judgeFaithfulness(
        answer: String,
        context: String,
        using client: LLMClient
    ) async throws -> JudgeVerdict {
        if isRefusal(answer) && citedTitles(in: answer).isEmpty && context.isEmpty { return .pass }

        let prompt = """
        You are a strict faithfulness judge for a retrieval-augmented system. You are given the \
        CONTEXT that was retrieved and an ANSWER written from it. Break the answer into its distinct \
        factual claims and check each one against the CONTEXT ONLY — never against your own knowledge. \
        A claim is supported only if the context states it or directly implies it. Ignore citation \
        markers like [Source: Title] and generic framing sentences that assert no fact.

        Respond in EXACTLY this format and nothing else:
        VERDICT: PASS
        — if every factual claim is supported by the context; otherwise
        VERDICT: FAIL
        CLAIM: <a short quote of the first unsupported or contradicted claim>
        CLAIM: <the next unsupported claim>
        — one CLAIM line per unsupported claim.

        CONTEXT:
        \(context)

        ANSWER:
        \(answer)

        Your verdict:
        """

        return try parseVerdict(try await client.complete(prompt))
    }

    // MARK: Helpers

    // Substring match for any refusal marker. Known Tier-1 limitation: a refusal-worded answer that
    // adds an unsupported claim but no [Source: …] citation (marker + claim + no citation) still passes
    // checkFaithfulness — there is no citation to reject and no refusal short-circuit is even reached.
    // Only the Tier 2 judge (rag ask --judge) catches it; documented as a Tier-1 hole in results.md.
    private static func isRefusal(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return refusalMarkers.contains { lowered.contains($0) }
    }

    private static func citedTitles(in output: String) -> [String] {
        let citationPattern = /\[source:\s*([^\]]+)\]/.ignoresCase()
        return output.matches(of: citationPattern).map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Parses the judge's `VERDICT:`/`CLAIM:` protocol defensively: only an explicit FAIL fails (the
    // named claims flow into the regenerate instruction), an explicit PASS passes, and anything else —
    // no verdict line, an unexpected verdict word — is unparseable and passed through with a warning.
    private static func parseVerdict(_ response: String) throws -> JudgeVerdict {
        let lines = response.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }

        guard let verdictLine = lines.first(where: { $0.lowercased().hasPrefix("verdict:") }) else {
            return .unparseable(response.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let verdict = verdictLine.dropFirst("verdict:".count).trimmingCharacters(in: .whitespaces).lowercased()
        if verdict.hasPrefix("pass") { return .pass }
        guard verdict.hasPrefix("fail") else {
            return .unparseable(response.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let claims = lines
            .filter { $0.lowercased().hasPrefix("claim:") }
            .map { $0.dropFirst("claim:".count).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let named = claims.isEmpty
            ? "one or more claims are not supported by the retrieved context"
            : claims.map { "\"\($0)\"" }.joined(separator: "; ")

        throw FaithfulnessError(
            "A faithfulness judge found unsupported claim(s) in your answer: \(named). Regenerate your "
            + "answer using ONLY facts stated in the retrieved context; drop or correct any claim the "
            + "context does not support, and keep a [Source: Title] citation for each remaining claim."
        )
    }
}
