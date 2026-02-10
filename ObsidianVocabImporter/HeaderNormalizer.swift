import Foundation

struct HeaderNormalizer {
    // Normalize header strings so we can match common variations:
    // - case-insensitive
    // - ignores spaces/underscores/hyphens/punctuation/colons (ASCII + fullwidth)
    // - removes BOM
    // - keeps letters/digits (including CJK) so aliases like "例句" remain matchable
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.unicodeScalars.first == UnicodeScalar(0xFEFF) { // BOM
            s = String(s.unicodeScalars.dropFirst())
        }
        s = s.lowercased()

        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)

        for u in s.unicodeScalars {
            if CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) {
                out.append(u)
            }
        }
        return String(out)
    }
}

