import Foundation

enum CSVDelimiter: String, CaseIterable, Identifiable, Codable, Sendable {
    case comma
    case tab
    case semicolon

    var id: String { rawValue }

    var byte: UInt8 {
        switch self {
        case .comma: return 0x2C // ,
        case .tab: return 0x09 // \t
        case .semicolon: return 0x3B // ;
        }
    }

    var displayName: String {
        switch self {
        case .comma: return "逗号 (,)"
        case .tab: return "制表符 (Tab)"
        case .semicolon: return "分号 (;)"
        }
    }

    static func detect(fromPrefix data: Data) -> CSVDelimiter {
        // Pick the delimiter that appears the most in the first non-empty line.
        // If tie/none, fall back to comma.
        guard !data.isEmpty else { return .comma }

        let slice = data.prefix(65_536)
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
        var text: String? = nil
        for enc in encodings {
            if let s = String(data: slice, encoding: enc) {
                text = s
                break
            }
        }
        guard let text else { return .comma }

        // Find first non-empty line.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .comma
        }

        func count(_ ch: Character) -> Int { first.reduce(0) { $0 + ($1 == ch ? 1 : 0) } }
        let comma = count(",")
        let tab = count("\t")
        let semi = count(";")

        let best = max(comma, tab, semi)
        if best == 0 { return .comma }
        // Prefer comma on ties (stable).
        if comma == best { return .comma }
        if tab == best { return .tab }
        return .semicolon
    }

    static func detect(from url: URL) -> CSVDelimiter {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return detect(fromPrefix: data)
        } catch {
            return .comma
        }
    }
}

struct CSVTable: Sendable {
    let header: [String]
    let rows: [[String]]
    let firstDataRowNumber: Int // 1-based, best-effort "row number" for logging
}

enum CSVError: Error, LocalizedError {
    case emptyFile
    case unreadableEncoding

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "CSV 文件为空。"
        case .unreadableEncoding:
            return "CSV 文件编码不支持（已尝试 UTF-8/UTF-16/Latin1）。"
        }
    }
}

struct CSVLoader {
    static func loadTable(from url: URL, delimiter: CSVDelimiter? = nil, progress: (@Sendable (Double) -> Void)? = nil) throws -> CSVTable {
        let text = try readText(from: url)
        let delim = delimiter ?? CSVDelimiter.detect(from: url)
        let rows = CSVParser.parse(text, delimiter: delim.byte, progress: progress)
        guard !rows.isEmpty else { throw CSVError.emptyFile }

        // Be tolerant of stray blank lines before the header (common after manual edits).
        guard let headerIndex = rows.firstIndex(where: { row in
            !row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else {
            throw CSVError.emptyFile
        }

        let header = rows[headerIndex]
        let body = Array(rows.dropFirst(headerIndex + 1))
        let firstDataRowNumber = headerIndex + 2 // header is row N, first data is N+1
        return CSVTable(header: header, rows: body, firstDataRowNumber: firstDataRowNumber)
    }

    private static func readText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
        for enc in encodings {
            if let s = String(data: data, encoding: enc) {
                return s
            }
        }
        throw CSVError.unreadableEncoding
    }
}

struct CSVParser {
    // Lightweight RFC4180-ish parser.
    // - Commas separate fields
    // - Quotes wrap fields; inside quotes, doubled quotes become a literal quote
    // - Newlines are allowed inside quoted fields
    static func parse(
        _ input: String,
        delimiter: UInt8 = 0x2C,
        maxRows: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [[String]] {
        let bytes = Array(input.utf8)
        let total = bytes.count

        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        field.reserveCapacity(64)

        var inQuotes = false
        var i = 0

        var lastProgressByte = 0
        func reportProgressIfNeeded() {
            guard let progress else { return }
            // Report roughly every 64 KiB to keep UI responsive but not chatty.
            if i - lastProgressByte >= 65_536 || i == total {
                lastProgressByte = i
                progress(total == 0 ? 1.0 : Double(i) / Double(total))
            }
        }

        func flushField() {
            let s = String(decoding: field, as: UTF8.self)
            row.append(s)
            field.removeAll(keepingCapacity: true)
        }

        func flushRow() {
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        parseLoop: while i < total {
            let b = bytes[i]

            if inQuotes {
                if b == 0x22 { // '"'
                    if i + 1 < total, bytes[i + 1] == 0x22 {
                        // Escaped quote "" -> "
                        field.append(0x22)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(b)
                }
            } else {
                switch b {
                case 0x22: // '"'
                    if field.isEmpty || field.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { // spaces/tabs
                        // Only treat quotes as opening quotes at field start.
                        // This makes the parser more robust when unquoted text contains quotes.
                        field.removeAll(keepingCapacity: true)
                        inQuotes = true
                    } else {
                        field.append(0x22)
                    }
                case delimiter:
                    flushField()
                case 0x0D: // '\r'
                    flushField()
                    flushRow()
                    if let maxRows, rows.count >= maxRows, !inQuotes {
                        break parseLoop
                    }
                    if i + 1 < total, bytes[i + 1] == 0x0A {
                        i += 1 // consume \n in CRLF
                    }
                case 0x0A: // '\n'
                    flushField()
                    flushRow()
                    if let maxRows, rows.count >= maxRows, !inQuotes {
                        break parseLoop
                    }
                default:
                    field.append(b)
                }
            }

            i += 1
            reportProgressIfNeeded()
        }

        // Final row (if the file didn't end with a newline).
        if (maxRows == nil || rows.count < maxRows!) && (!row.isEmpty || !field.isEmpty) {
            flushField()
            flushRow()
        }

        return rows
    }
}

extension CSVTable {
    func headerIndexMap() -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(header.count)

        for (idx, raw) in header.enumerated() {
            let key = HeaderNormalizer.normalize(raw)
            if !key.isEmpty {
                map[key] = idx
            }
        }
        return map
    }
}
