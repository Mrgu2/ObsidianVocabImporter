import AppKit
import Foundation

struct MomoExportPreview: Identifiable, Sendable {
    let id = UUID()
    let wordCount: Int
    let skippedIndexDuplicates: Int
    let skippedBatchDuplicates: Int
    let skippedFileDuplicates: Int
    let parseFailures: [ParseFailure]
    let previewText: String

    var skippedTotal: Int { skippedIndexDuplicates + skippedBatchDuplicates + skippedFileDuplicates }
}

enum MomoExportDestination {
    case clipboard
    case file(URL)
}

enum MomoWordExporter {
    static func preparePreview(
        vaultURL: URL,
        vocabCSVURL: URL,
        destination: MomoExportDestination? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MomoExportPreview {
        let store = MomoExportIndexStore(vaultURL: vaultURL)
        let index = try store.load()

        var fileExistingIDs: Set<String> = []
        if case let .file(fileURL) = destination, FileManager.default.fileExists(atPath: fileURL.path) {
            fileExistingIDs = readExistingWordIDs(from: fileURL)
        }

        let parsed = try parseVocabWords(url: vocabCSVURL, progress: progress)

        var outWords: [String] = []
        outWords.reserveCapacity(parsed.words.count)

        var skippedIndex = 0
        var skippedFile = 0

        for w in parsed.words {
            let id = VocabClip.makeID(word: w)
            if index.contains(id) {
                skippedIndex += 1
                continue
            }
            if fileExistingIDs.contains(id) {
                skippedFile += 1
                continue
            }
            outWords.append(w)
        }

        let text = outWords.joined(separator: "\n") + (outWords.isEmpty ? "" : "\n")
        return MomoExportPreview(
            wordCount: outWords.count,
            skippedIndexDuplicates: skippedIndex,
            skippedBatchDuplicates: parsed.skippedBatchDuplicates,
            skippedFileDuplicates: skippedFile,
            parseFailures: parsed.failures,
            previewText: text
        )
    }

    static func export(
        vaultURL: URL,
        vocabCSVURL: URL,
        destination: MomoExportDestination,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> String {
        let store = MomoExportIndexStore(vaultURL: vaultURL)
        var exportedIndex = try store.load()

        // If exporting to a file, "self-heal" by scanning existing file lines as already-exported.
        var fileExistingIDs: Set<String> = []
        if case let .file(u) = destination {
            if FileManager.default.fileExists(atPath: u.path) {
                fileExistingIDs = readExistingWordIDs(from: u)
                exportedIndex.formUnion(fileExistingIDs)
            }
        }

        let parsed = try parseVocabWords(url: vocabCSVURL, progress: progress)

        var outWords: [String] = []
        outWords.reserveCapacity(parsed.words.count)

        var skippedIndex = 0
        var skippedFile = 0

        for w in parsed.words {
            let id = VocabClip.makeID(word: w)
            if fileExistingIDs.contains(id) {
                skippedFile += 1
                continue
            }
            if exportedIndex.contains(id) {
                skippedIndex += 1
                continue
            }
            outWords.append(w)
            exportedIndex.insert(id)
        }

        let text = outWords.joined(separator: "\n") + (outWords.isEmpty ? "" : "\n")

        switch destination {
        case .clipboard:
            // Pasteboard is UI-facing; do it on the main thread.
            let work = {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.sync(execute: work)
            }

        case .file(let url):
            try writeWordsAppending(text: text, to: url)
        }

        try store.save(exportedIndex)

        let logger = ImportLogger(vaultURL: vaultURL)
        var logLines: [String] = []
        if !parsed.failures.isEmpty {
            logLines.append("墨墨导出：解析失败（已跳过行）：")
            logLines.append(contentsOf: parsed.failures.map { $0.logLine })
        }
        if !logLines.isEmpty {
            try logger.appendSession(title: "MoMo Export", lines: logLines)
        }

        var summary = "墨墨单词本导出摘要\n"
        summary += "- 新增单词：\(outWords.count)\n"
        summary += "- 跳过重复：\(skippedIndex + parsed.skippedBatchDuplicates + skippedFile)\n"
        summary += "  - 已导出（索引/历史）：\(skippedIndex)\n"
        summary += "  - CSV 内重复：\(parsed.skippedBatchDuplicates)\n"
        summary += "  - 目标文件已存在：\(skippedFile)\n"
        summary += "- 解析失败：\(parsed.failures.count)\n"
        switch destination {
        case .clipboard:
            summary += "- 输出：已复制到剪贴板\n"
        case .file(let url):
            summary += "- 输出：\(url.path)\n"
        }
        return summary
    }

    // MARK: - Parsing

    private struct ParsedWords {
        let words: [String]            // de-duped within CSV
        let failures: [ParseFailure]
        let skippedBatchDuplicates: Int
    }

    private static func parseVocabWords(url: URL, progress: (@Sendable (Double) -> Void)?) throws -> ParsedWords {
        let table = try CSVLoader.loadTable(from: url, delimiter: nil, progress: progress)
        let map = table.headerIndexMap()

        let auto = ColumnSchemaMatcher.autoMap(schema: .vocabulary, headerIndexMap: map)
        var wordIdx: Int? = auto.fieldToHeaderIndex["word"]

        // If auto-mapping fails, try the user-saved column mapping (from the import "列映射" dialog).
        if wordIdx == nil {
            let signature = sha1Hex(table.header.map { HeaderNormalizer.normalize($0) }.joined(separator: "|"))
            if let stored = ColumnMappingStore.load(kind: .vocabulary, headerSignature: signature),
               let idx = stored.fieldToHeaderIndex["word"],
               idx >= 0,
               idx < table.header.count {
                wordIdx = idx
            }
        }

        guard let wordIdx else {
            throw NSError(domain: "OEI", code: 21, userInfo: [NSLocalizedDescriptionKey: "词汇 CSV 缺少必需列：word（可尝试在导入预览中完成列映射后再导出）"])
        }

        var failures: [ParseFailure] = []
        var out: [String] = []
        out.reserveCapacity(table.rows.count)

        var seen: Set<String> = []
        var skippedBatch = 0

        for (i, row) in table.rows.enumerated() {
            let lineNo = table.firstDataRowNumber + i
            if row.allSatisfy({ $0.oeiTrimmed().isEmpty }) {
                continue
            }

            let word = (wordIdx < row.count ? row[wordIdx] : "").oeiTrimmed()
            if word.isEmpty {
                failures.append(ParseFailure(fileName: url.lastPathComponent, lineNumber: lineNo, reason: "单词为空"))
                continue
            }

            let id = VocabClip.makeID(word: word)
            if seen.contains(id) {
                skippedBatch += 1
                continue
            }
            seen.insert(id)
            out.append(word)
        }

        return ParsedWords(words: out, failures: failures, skippedBatchDuplicates: skippedBatch)
    }

    // MARK: - File helpers

    private static func readExistingWordIDs(from url: URL) -> Set<String> {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var ids: Set<String> = []
        ids.reserveCapacity(1024)
        for line in s.components(separatedBy: .newlines) {
            let w = line.oeiTrimmed()
            if w.isEmpty { continue }
            ids.insert(VocabClip.makeID(word: w))
        }
        return ids
    }

    private static func writeWordsAppending(text: String, to url: URL) throws {
        guard !text.isEmpty else { return }

        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: url.path) {
            // Append (atomically) while keeping newline boundaries.
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var combined = existing
            if !combined.isEmpty, !combined.hasSuffix("\n") {
                combined += "\n"
            }
            combined += text
            try AtomicFileWriter.writeString(combined, to: url)
        } else {
            try AtomicFileWriter.writeString(text, to: url)
        }
    }
}
