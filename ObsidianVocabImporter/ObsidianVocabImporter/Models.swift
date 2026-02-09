import CryptoKit
import Foundation

enum ImportMode: String, CaseIterable, Identifiable {
    case sentences
    case vocabulary
    case merged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sentences: return "句子"
        case .vocabulary: return "词汇"
        case .merged: return "全部合并"
        }
    }
}

enum YearCompletionStrategy: String, CaseIterable, Identifiable {
    case systemYear
    case mostCommonSentenceYear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemYear:
            return "使用当前系统年份"
        case .mostCommonSentenceYear:
            return "使用句子 CSV 中出现最多的年份"
        }
    }
}

enum MergedLayoutStrategy: String, CaseIterable, Identifiable {
    // Default behavior: sections, vocab first then sentences.
    case vocabThenSentences
    // Interleave vocab + sentences in a single section (best-effort, without real timestamps).
    case interleaved
    // Sentences first; each sentence can optionally list related vocab words.
    case sentencePrimary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vocabThenSentences:
            return "先词后句"
        case .interleaved:
            return "按时间线交错"
        case .sentencePrimary:
            return "以句子为主"
        }
    }
}

struct SentenceClip: Identifiable, Hashable, Sendable {
    let id: String // sent_<sha1>
    let sentence: String
    let translation: String
    let url: String? // nil when empty
    let date: String // yyyy-MM-dd

    static func makeID(sentence: String, url: String?) -> String {
        // Why sentence + URL:
        // The same sentence can appear in multiple sources (different links/contexts).
        // Treating (normalized sentence, normalized URL) as the dedup key avoids incorrectly
        // collapsing distinct clips into one when the sentence text matches but the source differs.
        let normalizedSentence = sentence
            .oeiTrimmed()
            .lowercased()
            .oeiCompressWhitespaceToSingleSpaces()
        let normalizedURL = (url ?? "").oeiTrimmed()
        let key = normalizedSentence + "|" + normalizedURL
        return "sent_" + sha1Hex(key)
    }
}

struct VocabClip: Identifiable, Hashable, Sendable {
    let id: String // vocab_<sha1>
    let word: String
    let phonetic: String?
    let translation: String
    let date: String // yyyy-MM-dd

    static func makeID(word: String) -> String {
        // Why only word:
        // For vocabulary review, the primary identity is the word itself. Phonetic/translation
        // may change across exports or as the user edits notes, but we still want it considered
        // the same vocab item for dedup purposes.
        let normalizedWord = word.oeiTrimmed().lowercased()
        return "vocab_" + sha1Hex(normalizedWord)
    }
}

struct ParseFailure: Identifiable, Hashable, Sendable {
    let id = UUID()
    let fileName: String
    let lineNumber: Int // 1-based, including header
    let reason: String

    var logLine: String {
        if lineNumber > 0 {
            return "\(fileName) line \(lineNumber): \(reason)"
        }
        return "\(fileName): \(reason)"
    }
}

struct DateParsing {
    static func parseSentenceDate(_ raw: String) -> (year: Int, month: Int, day: Int)? {
        let nums = extractInts(raw)
        guard nums.count >= 3 else { return nil }
        let y = nums[0], m = nums[1], d = nums[2]
        guard isValid(year: y, month: m, day: d) else { return nil }
        return (y, m, d)
    }

    static func parseVocabularyDate(_ raw: String, fallbackYear: Int) -> (year: Int, month: Int, day: Int)? {
        let nums = extractInts(raw)

        // Some exporters may include a year; accept it for robustness.
        if nums.count >= 3 {
            if nums[0] >= 1000 {
                // yyyy-mm-dd
                let y = nums[0], m = nums[1], d = nums[2]
                guard isValid(year: y, month: m, day: d) else { return nil }
                return (y, m, d)
            }
            if nums[2] >= 1000 {
                // mm-dd-yyyy
                let m = nums[0], d = nums[1], y = nums[2]
                guard isValid(year: y, month: m, day: d) else { return nil }
                return (y, m, d)
            }
        }

        guard nums.count >= 2 else { return nil }
        let y = fallbackYear, m = nums[0], d = nums[1]
        guard isValid(year: y, month: m, day: d) else { return nil }
        return (y, m, d)
    }

    static func formatYMD(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func extractInts(_ raw: String) -> [Int] {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1000...9999).contains(year) else { return false }
        guard (1...12).contains(month) else { return false }
        guard (1...31).contains(day) else { return false }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        var dc = DateComponents()
        dc.year = year
        dc.month = month
        dc.day = day

        guard let date = cal.date(from: dc) else { return false }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }
}

func sha1Hex(_ input: String) -> String {
    // Stable across machines because it only depends on UTF-8 bytes.
    let digest = Insecure.SHA1.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

extension String {
    func oeiTrimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func oeiCompressWhitespaceToSingleSpaces() -> String {
        // Matches requirement: trim + lowercase + compress multiple spaces.
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
