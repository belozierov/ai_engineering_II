// Shared mutable state across the hosted tools and the ask loop: the titles the most recent search
// actually retrieved, plus the packed (post-sanitize) context those titles produced. Tier 1
// faithfulness checks citations against the titles (so a made-up [Source: X] can't pass); the Tier 2
// judge grades the answer against the context. Mirrors WikiDeps.last_context_titles in data.py:
// search sets it, a refusal clears it, and get_full_article deliberately does NOT touch it.
actor RetrievedTitlesBox {

    private var titles: [String] = []
    private var packedContext = ""

    func set(_ titles: [String]) {
        self.titles = titles
    }

    func set(context: String) {
        packedContext = context
    }

    func clear() {
        titles = []
        packedContext = ""
    }

    func current() -> [String] {
        titles
    }

    func context() -> String {
        packedContext
    }
}
