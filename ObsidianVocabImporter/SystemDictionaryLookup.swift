import Foundation

#if canImport(CoreServices)
import CoreServices
#endif

enum SystemDictionaryLookup {
    private static func containsHan(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    private static func hasPinyinDiacritics(_ s: String) -> Bool {
        // Heuristic: only strip romanization when we see typical pinyin tone marks.
        // This avoids accidentally removing normal English like "CPU" after Chinese.
        let marks = "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛÜ"
        return s.rangeOfCharacter(from: CharacterSet(charactersIn: marks)) != nil
    }

    private static func stripPinyinRomanizationIfPresent(_ s: String) -> String {
        guard hasPinyinDiacritics(s) else { return s }

        // IMPORTANT: don't delete normal English that appears after Chinese.
        // Only remove latin tokens that themselves contain typical pinyin tone marks.
        let marks = "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛÜ"
        let markSet = CharacterSet(charactersIn: marks)
        let tokenRe = try? NSRegularExpression(
            // Latin word (with combining marks/apostrophes/hyphens) that contains a tone-mark letter.
            pattern: #"\b[\p{Script=Latin}\p{M}'’\-]*["# + marks + #"][\p{Script=Latin}\p{M}'’\-]*\b[;,.!?]?"#,
            options: []
        )
        guard let tokenRe else { return s }

        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = tokenRe.matches(in: s, options: [], range: full)
        if matches.isEmpty { return s }

        // Replace from the end to keep ranges valid.
        var out = s
        for m in matches.reversed() {
            let r = Range(m.range, in: out) ?? nil
            if let r {
                // Only remove tokens that actually contain marks (extra safety).
                if out[r].rangeOfCharacter(from: markSet) != nil {
                    out.removeSubrange(r)
                }
            }
        }

        // Clean up whitespace left by removals.
        out = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return out
    }

    private static func dropLeadingHeaderLines(_ lines: [String], termLower: String) -> [String] {
        // DictionaryServices often begins with a header line like:
        // "captain | BrE ... | AmE ... |"
        // Drop leading lines that look like headers (e.g. contain pipes) and contain no Chinese.
        // IMPORTANT: do not drop ordinary English definitions that happen to begin with the term.
        var out = lines
        while let first = out.first {
            let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                out.removeFirst()
                continue
            }
            if containsHan(t) { break }
            let tl = t.lowercased()
            if tl == termLower || (tl.contains(termLower) && t.contains("|")) {
                out.removeFirst()
                continue
            }
            break
        }
        return out
    }

    static func lookupMeaningSingleLine(term: String, mode: DictionaryLookupMode) -> String? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        #if canImport(CoreServices)
        let cf = t as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))

        func cleanDefinition(_ raw: String) -> String {
            let normalizedLines = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0) }

            let bodyLines = dropLeadingHeaderLines(normalizedLines, termLower: t.lowercased())

            // Store as one line for the capture UI; we will render it as multi-line Markdown later.
            var collapsed = bodyLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")

            collapsed = stripPinyinRomanizationIfPresent(collapsed)

            // Drop leading English headers as much as possible:
            // Prefer starting from the first sense marker (①②...) if it exists; otherwise start from
            // the first Chinese character.
            let markers = Array("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")
            let markerIdx: String.Index? = {
                for m in markers {
                    if let r = collapsed.firstIndex(of: m) { return r }
                }
                return nil
            }()
            let hanIdx: String.Index? = collapsed.unicodeScalars.firstIndex(where: { scalar in
                let v = scalar.value
                return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            })?.samePosition(in: collapsed)

            let start: String.Index? = {
                switch (markerIdx, hanIdx) {
                case (nil, nil): return nil
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (let a?, let b?): return min(a, b)
                }
            }()
            if let start {
                collapsed = String(collapsed[start...]).oeiTrimmed()
            }

            return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // DictionaryServices searches dictionaries enabled in Dictionary.app preferences.
        // We can't reliably select a specific dictionary via public API, so "English fallback"
        // is implemented as: accept English-only definitions when present.
        guard let unmanaged = DCSCopyTextDefinition(nil, cf, range) else { return nil }
        let raw = unmanaged.takeRetainedValue() as String
        let cleaned = cleanDefinition(raw)
        if cleaned.isEmpty { return nil }

        let hasHan = containsHan(cleaned)
        switch mode {
        case .preferChineseThenEnglish:
            return cleaned
        case .preferChineseOnly:
            return hasHan ? cleaned : nil
        case .englishOnly:
            // Best-effort: if the definition contains Chinese, still return it rather than showing empty.
            return cleaned
        }
        #else
        return nil
        #endif
    }
}
