import Foundation
import ApplicationServices

/// Reads the focused text field via Accessibility and detects likely
/// spelling corrections between the pasted text and the field's current text.
enum FieldReader {

    static func readFocusedFieldText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                            kAXValueAttribute as CFString,
                                            &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }
        return text
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i-1] == y[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    /// Detects a single-word spelling fix between the pasted text and the
    /// field's current text. Returns the corrected word, or nil.
    /// Heuristic (all must hold):
    ///  - exactly one word differs between the pasted words and current words
    ///  - edit distance <= 40% of the corrected word's length
    ///  - same first letter (case-insensitive) OR pure case change
    ///  - corrected word length >= 4
    ///  - corrected word not already in the dictionary
    static func spellingFix(before: String, after: String, vocab: [String]) -> String? {
        let clean: (String) -> [String] = { s in
            s.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        let a = clean(before)
        // The field may contain more than the pasted text; find the pasted
        // region by locating the closest-length window? Keep simple: compare
        // against the whole field only when word counts match, else compare
        // against a window of the same length that best overlaps.
        let fieldWords = clean(after)
        guard !a.isEmpty, fieldWords.count >= a.count else { return nil }

        var best: (diff: Int, bWindow: [String])? = nil
        let maxOffset = fieldWords.count - a.count
        for off in 0...min(maxOffset, 40) {
            let window = Array(fieldWords[off..<(off + a.count)])
            let diff = zip(a, window).filter { $0 != $1 }.count
            if best == nil || diff < best!.diff { best = (diff, window) }
            if diff <= 1 { break }
        }
        guard let (diffCount, b) = best, diffCount == 1 else { return nil }

        for (orig, edited) in zip(a, b) where orig != edited {
            let candidate = edited
            guard candidate.count >= 4 else { return nil }
            let caseOnly = orig.lowercased() == candidate.lowercased()
            let sameFirst = orig.lowercased().first == candidate.lowercased().first
            guard caseOnly || sameFirst else { return nil }
            let dist = levenshtein(orig, candidate)
            let budget = max(1, Int(Double(candidate.count) * 0.4))
            guard caseOnly || (dist > 0 && dist <= budget) else { return nil }
            let known = vocab.contains { $0.compare(candidate, options: .caseInsensitive) == .orderedSame }
            guard !known else { return nil }
            mflog("FieldReader: spelling fix candidate '\(orig)' -> '\(candidate)'")
            return candidate
        }
        return nil
    }
}
