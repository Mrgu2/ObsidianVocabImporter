import Foundation

struct SubtitleCue: Identifiable, Hashable, Sendable {
    let id = UUID()
    let start: String
    let end: String
    let text: String

    var timeRangeDisplay: String {
        if start.isEmpty && end.isEmpty { return "" }
        if end.isEmpty { return start }
        return "\(start)–\(end)"
    }
}

enum SubtitleParserError: Error, LocalizedError {
    case unsupportedExtension
    case unreadableEncoding

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension:
            return "仅支持 .srt 或 .vtt。"
        case .unreadableEncoding:
            return "字幕文件编码不支持（已尝试 UTF-8/UTF-16/Latin1）。"
        }
    }
}

enum SubtitleParser {
    static func parse(url: URL) throws -> [SubtitleCue] {
        let ext = url.pathExtension.lowercased()
        guard ext == "srt" || ext == "vtt" else { throw SubtitleParserError.unsupportedExtension }
        guard let text = VaultUtilities.readTextFileLossy(url) else { throw SubtitleParserError.unreadableEncoding }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if ext == "srt" {
            return parseSRT(normalized)
        }
        return parseVTT(normalized)
    }

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var out: [SubtitleCue] = []
        out.reserveCapacity(max(32, lines.count / 4))

        var i = 0
        while i < lines.count {
            // Skip blank lines.
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                i += 1
            }
            if i >= lines.count { break }

            // Optional numeric index line.
            let first = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if Int(first) != nil {
                i += 1
                if i >= lines.count { break }
            }

            let timeLine = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (start, end) = parseTimeLine(timeLine) else {
                i += 1
                continue
            }
            i += 1

            var textLines: [String] = []
            while i < lines.count {
                let t = lines[i]
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                textLines.append(t)
                i += 1
            }

            let cueText = cleanCueText(textLines.joined(separator: " "))
            if !cueText.isEmpty {
                out.append(SubtitleCue(start: normalizeTime(start), end: normalizeTime(end), text: cueText))
            }
            i += 1
        }

        return out
    }

    private static func parseVTT(_ text: String) -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var out: [SubtitleCue] = []
        out.reserveCapacity(max(32, lines.count / 4))

        var i = 0

        // Skip WEBVTT header and optional metadata until first blank line.
        if i < lines.count, lines[i].trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("WEBVTT") {
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                i += 1
            }
        }

        while i < lines.count {
            // Skip blank lines.
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                i += 1
            }
            if i >= lines.count { break }

            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip NOTE blocks.
            if line.uppercased().hasPrefix("NOTE") {
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    i += 1
                }
                continue
            }

            // Cue may start with an identifier line.
            var timeLine = line
            if !timeLine.contains("-->"), i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.contains("-->") {
                    timeLine = next
                    i += 1
                }
            }

            guard let (start, end) = parseTimeLine(timeLine) else {
                i += 1
                continue
            }
            i += 1

            var textLines: [String] = []
            while i < lines.count {
                let t = lines[i]
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                // Skip STYLE blocks that can appear between cues.
                if t.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("STYLE") {
                    break
                }
                textLines.append(t)
                i += 1
            }

            let cueText = cleanCueText(textLines.joined(separator: " "))
            if !cueText.isEmpty {
                out.append(SubtitleCue(start: normalizeTime(start), end: normalizeTime(end), text: cueText))
            }

            i += 1
        }

        return out
    }

    private static func parseTimeLine(_ line: String) -> (String, String)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let start = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)

        let rhs = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let end = rhs.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard !start.isEmpty else { return nil }
        return (start, end)
    }

    private static func normalizeTime(_ s: String) -> String {
        // SRT uses comma for milliseconds, VTT uses dot.
        s.replacingOccurrences(of: ",", with: ".")
    }

    private static func cleanCueText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "\t", with: " ")
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")

        // Strip basic HTML tags (<i>, <b>, <c>, ...). Keep the inner text.
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(location: 0, length: (t as NSString).length)
            t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
        }

        return t.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
    }
}

