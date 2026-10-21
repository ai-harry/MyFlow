import Foundation

/// Deterministic, zero-latency cleanup for very short, simple dictations.
/// Returns nil whenever anything looks risky so the caller falls back to the
/// LLM. Only touches fillers, immediate repeats, spacing, capitalisation and
/// terminal punctuation; it never rewrites wording.
enum LocalCleanup {
    static let maxWords = 12

    private static let fillers: Set<String> = [
        "um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mmm", "mhm",
    ]
    /// Words/phrases that signal corrections, dictation commands or structure.
    private static let riskyWords: Set<String> = [
        "wait", "actually", "scratch", "sorry", "rather", "oops", "nevermind", "meant",
        "bullet", "bullets", "paragraph", "newline", "quote", "unquote", "comma", "period",
        "colon", "semicolon", "hyphen", "dash", "parenthesis", "first", "second", "third",
        "next", "delete", "undo", "redo", "cancel",
    ]
    private static let riskyPhrases = ["new line", "never mind", "hold on", "no no", "i mean to say", "let me rephrase"]
    private static let noCollapse: Set<String> = ["had", "that", "very", "no", "ha", "bye", "really", "so", "yes", "now"]
    private static let interrogatives: Set<String> = [
        "who", "what", "when", "where", "why", "how", "is", "are", "do", "does", "did", "can", "could",
        "would", "will", "should", "shall", "was", "were", "have", "has", "which", "whose",
    ]
    private static let terminals: Set<Character> = [".", "?", "!"]

    static func fastPath(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Structure / symbols we will not reason about locally.
        if text.contains("\n") || text.contains("--") || text.contains("—") || text.contains("…") { return nil }
        if text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return nil }
        if text.contains(where: { "\"“”()[]{}:;@#/\\*_<>=+&%$".contains($0) }) { return nil }
        let lower = text.lowercased()
        for p in riskyPhrases where lower.contains(p) { return nil }

        var toks = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard toks.count <= maxWords else { return nil }

        // Single sentence only: terminal punctuation may appear on the last token alone.
        for t in toks.dropLast() where t.last.map(terminals.contains) == true { return nil }
        for t in toks {
            let body = String(t.drop(while: { !$0.isLetter && !$0.isNumber }))
            // Interior dots (urls, abbreviations, "e.g."), or odd symbols => LLM.
            let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: ".,?!"))
            if trimmed.contains(".") || trimmed.contains(",") { return nil }
            if riskyWords.contains(core(t)) { return nil }
        }

        // 1. Remove fillers.
        var out: [String] = []
        var i = 0
        func lastTerminal(_ s: String) -> Character? { s.last.flatMap { terminals.contains($0) ? $0 : nil } }
        func dropToken(_ t: String) {
            // Preserve a sentence-final mark carried by the removed token.
            if let term = lastTerminal(t), var prev = out.popLast() {
                while prev.last == "," { prev.removeLast() }
                if lastTerminal(prev) == nil { prev.append(term) }
                out.append(prev)
            }
        }
        while i < toks.count {
            let t = toks[i]
            let c = core(t)
            let hasComma = t.hasSuffix(",")
            let atStart = out.isEmpty
            let prevComma = out.last?.hasSuffix(",") ?? false
            let atEnd = i == toks.count - 1
            let nextC = i + 1 < toks.count ? core(toks[i + 1]) : ""
            if fillers.contains(c) {
                dropToken(t); i += 1; continue
            }
            // "like" only as a clear filler: "like," anywhere.
            if c == "like", hasComma {
                dropToken(t); i += 1; continue
            }
            // "you know" / "I mean" only when comma-delimited or at an edge.
            if (c == "you" && nextC == "know") || (c == "i" && nextC == "mean") {
                let second = toks[i + 1]
                let delimitedAfter = second.hasSuffix(",") || i + 2 == toks.count
                let delimitedBefore = atStart || prevComma
                if delimitedAfter && delimitedBefore && !(i + 2 == toks.count && atStart) {
                    dropToken(second); i += 2; continue
                }
                // "..., you know" at the end after a comma.
                _ = atEnd
            }
            out.append(t); i += 1
        }
        toks = out
        guard !toks.isEmpty else { return nil }

        // 2. Collapse immediate repeats (single word, then two-word phrase).
        func collapse(_ n: Int) {
            var r: [String] = []
            var k = 0
            while k < toks.count {
                if k + 2 * n <= toks.count {
                    let a = toks[k..<k + n].map(core), b = toks[k + n..<k + 2 * n].map(core)
                    let ok = a == b && !a.isEmpty && !a.contains("")
                        && !(n == 1 && noCollapse.contains(a[0]))
                        && !toks[k..<k + n - 1].contains(where: { $0.last.map(terminals.contains) == true })
                    if ok { k += n; continue }   // drop the first copy, keep the later one
                }
                r.append(toks[k]); k += 1
            }
            toks = r
        }
        collapse(1); collapse(2)

        // 3. Join, tidy.
        var s = toks.joined(separator: " ")
        s = s.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ([,.?!])", with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        // Fix a leading lowercase "i" pronoun forms.
        s = s.replacingOccurrences(of: "(?<![A-Za-z'’])i(?=$|[ ,.?!]|'(m|ll|ve|d))", with: "I",
                                   options: .regularExpression)
        guard let first = s.first, first.isLetter else { return nil }
        // Leave mixed-case words alone ("iPhone", "eBay", "macOS").
        let firstWord = s.prefix { $0 != " " && $0 != "," }
        if firstWord == firstWord.lowercased() { s = first.uppercased() + s.dropFirst() }

        // 4. Terminal punctuation.
        if let last = s.last, terminals.contains(last) {
            while s.hasSuffix(",.") { s.removeLast(2); s.append(".") }
        } else {
            let w = core(String(s.split(separator: " ").first ?? ""))
            if interrogatives.contains(w) { return nil }   // can't tell statement vs question
            s.append(".")
        }
        return s
    }

    /// Lowercased word with surrounding punctuation removed.
    private static func core(_ t: String) -> String {
        t.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }
}
