import Foundation

/// Conservative application onto canonical words. Original text must agree with
/// the span, punctuation survives, and a word can be claimed only once. A phrase
/// occupies one timed slot enclosing the actual original words (no invented IDs).
enum VocabularyWordReplacer {
    static func apply(_ replacements: [WorkerVocabularyReplacement], to words: [ReconciledWordsRecord.Word]) -> [ReconciledWordsRecord.Word] {
        var claimed = Set<Int>()
        var edits: [Int: (Range<Int>, ReconciledWordsRecord.Word)] = [:]
        for replacement in replacements.sorted(by: {
            let a = $0.endSeconds - $0.startSeconds, b = $1.endSeconds - $1.startSeconds
            return a == b ? $0.startSeconds < $1.startSeconds : a > b
        }) {
            guard replacement.startSeconds.isFinite, replacement.endSeconds.isFinite,
                  replacement.startSeconds >= 0, replacement.endSeconds > replacement.startSeconds,
                  !replacement.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = replacement.startSeconds * 1_000, end = replacement.endSeconds * 1_000
            let indices = words.indices.filter { index in
                let word = words[index]
                guard let s = word.startMs else { return false }
                return Double(s) >= start - 1 && Double(s) < end - 1
            }
            guard let first = indices.first, let last = indices.last,
                  indices == Array(first...last), !indices.contains(where: { claimed.contains($0) }),
                  let firstStart = words[first].startMs, abs(Double(firstStart) - start) <= 100,
                  key(indices.map { words[$0].text }.joined(separator: " ")) == key(replacement.original) else { continue }
            let original = words[first...last].map(\.text).joined(separator: " ")
            let leading = String(original.prefix { !$0.isLetter && !$0.isNumber })
            let trailing = String(original.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            let text = (replacement.replacement.hasPrefix(leading) ? "" : leading) + replacement.replacement.trimmingCharacters(in: .whitespacesAndNewlines) + (replacement.replacement.hasSuffix(trailing) ? "" : trailing)
            let range = first..<(last + 1)
            edits[first] = (range, .init(id: words[first].id, text: text, startMs: words[first].startMs,
                                       endMs: words[last].endMs, enclosingStartMs: words[first].enclosingStartMs,
                                       enclosingEndMs: words[last].enclosingEndMs))
            claimed.formUnion(range)
        }
        return words.indices.compactMap { index in
            if let edit = edits[index] { return edit.1 }
            return claimed.contains(index) ? nil : words[index]
        }
    }

    private static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
    }
}
