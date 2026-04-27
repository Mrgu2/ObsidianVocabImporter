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

struct MomoCloudSyncResult: Sendable {
    let summary: String
    let previewText: String
    let appendedCount: Int
    let historicalIndexHits: Int
    let skippedBatchDuplicates: Int
    let skippedRemoteDuplicates: Int
    let localIndexSaveSucceeded: Bool
    let parseFailures: [ParseFailure]
}

struct MomoCloudSyncPreview: Identifiable, Sendable {
    let id = UUID()
    let notepadTitle: String
    let notepadID: String
    let action: String
    let candidateWords: [String]
    let wordsToAppend: [String]
    let historicalIndexHits: Int
    let skippedBatchDuplicates: Int
    let skippedRemoteDuplicates: Int
    let parseFailures: [ParseFailure]
    let previewText: String

    var appendedCount: Int { wordsToAppend.count }
    var skippedTotal: Int { skippedBatchDuplicates + skippedRemoteDuplicates }

    var confirmationMessage: String {
        return """
        目标词本：\(notepadTitle)
        词本 ID：\(notepadID)
        动作：\(action)
        将追加：\(appendedCount) 个单词
        跳过重复：\(skippedTotal) 个
        本地历史命中：\(historicalIndexHits) 个（仅提示，不阻止补齐远端）
        """
    }
}

enum MomoExportDestination {
    case clipboard
    case file(URL)
}

enum MomoWordExporter {
    // MARK: - Vault Export (Recommended)

    static func preparePreviewFromVault(
        vaultURL: URL,
        preferences: PreferencesSnapshot,
        destination: MomoExportDestination? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MomoExportPreview {
        let store = MomoExportIndexStore(vaultURL: vaultURL)
        let index = try store.load()

        var fileExistingIDs: Set<String> = []
        if case let .file(fileURL) = destination, FileManager.default.fileExists(atPath: fileURL.path) {
            fileExistingIDs = readExistingWordIDs(from: fileURL)
        }

        let parsed = try parseVocabWordsFromVault(vaultURL: vaultURL, preferences: preferences, progress: progress)

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

    static func exportFromVault(
        vaultURL: URL,
        preferences: PreferencesSnapshot,
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

        let parsed = try parseVocabWordsFromVault(vaultURL: vaultURL, preferences: preferences, progress: progress)

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
            logLines.append("墨墨导出：解析失败（已跳过）：")
            logLines.append(contentsOf: parsed.failures.map { $0.logLine })
        }
        if !logLines.isEmpty {
            try logger.appendSession(title: "MoMo Export (Vault)", lines: logLines)
        }

        var summary = "墨墨单词本导出摘要（扫描 Vault）\n"
        summary += "- 扫描目录：\(VaultUtilities.outputRootURL(vaultURL: vaultURL, preferences: preferences).path)\n"
        summary += "- 新增单词：\(outWords.count)\n"
        summary += "- 跳过重复：\(skippedIndex + parsed.skippedBatchDuplicates + skippedFile)\n"
        summary += "  - 已导出（索引/历史）：\(skippedIndex)\n"
        summary += "  - Vault 内重复：\(parsed.skippedBatchDuplicates)\n"
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

    static func prepareMomoCloudSyncPreview(
        vaultURL: URL,
        preferences: PreferencesSnapshot,
        settings: MomoCloudSettings,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MomoCloudSyncPreview {
        guard settings.canUseAPI else { throw MomoAPIError.missingToken }

        progress?(0.0, "正在扫描 Vault 词汇…")
        let store = MomoExportIndexStore(vaultURL: vaultURL, indexFileName: VaultSupportPaths.momoCloudSyncIndexFileName)
        let syncedIndex = try store.load()
        let parsed = try parseVocabWordsFromVault(vaultURL: vaultURL, preferences: preferences) { p in
            progress?(min(0.35, p * 0.35), "正在扫描 Vault 词汇…")
        }

        let candidateWords = parsed.words
        let historicalIndexHits = candidateWords.reduce(into: 0) { count, word in
            if syncedIndex.contains(VocabClip.makeID(word: word)) {
                count += 1
            }
        }

        progress?(0.4, "正在连接墨墨开放 API…")
        let client = try MomoAPIClient(token: settings.trimmedToken)
        let notepadTitle = settings.trimmedNotepadTitle
        let selectedNotepadID = settings.trimmedSelectedNotepadID

        let action: String
        let notepadID: String
        let resolvedTitle: String
        let skippedRemote: Int
        let appendedWords: [String]

        if let selectedNotepadID {
            progress?(0.7, "正在读取墨墨云词本…")
            let notepad = try await client.getNotepad(id: selectedNotepadID)
            let merged = mergeMomoNotepadContent(existingContent: notepad.content, newWords: candidateWords)
            skippedRemote = merged.skippedRemoteDuplicates
            appendedWords = merged.appendedWords
            resolvedTitle = notepad.title

            if appendedWords.isEmpty {
                action = "未更新（墨墨云词本中已存在全部候选词）"
                notepadID = notepad.id
            } else {
                action = "将更新已有云词本"
                notepadID = notepad.id
            }
        } else {
            let merged = mergeMomoNotepadContent(existingContent: "", newWords: candidateWords)
            skippedRemote = merged.skippedRemoteDuplicates
            appendedWords = merged.appendedWords
            resolvedTitle = notepadTitle
            if appendedWords.isEmpty {
                action = "未创建（没有可同步的新单词）"
                notepadID = "-"
            } else {
                action = "将创建新云词本"
                notepadID = "将创建新词本"
            }
        }

        let logger = ImportLogger(vaultURL: vaultURL)
        var logLines: [String] = []
        if !parsed.failures.isEmpty {
            logLines.append("墨墨云词本同步预览：解析失败（已跳过）：")
            logLines.append(contentsOf: parsed.failures.map { $0.logLine })
        }
        if !logLines.isEmpty {
            try logger.appendSession(title: "MoMo Cloud Sync Preview", lines: logLines)
        }

        let preview = appendedWords.joined(separator: "\n") + (appendedWords.isEmpty ? "" : "\n")
        progress?(1.0, "墨墨云词本差异检查完成。")
        return MomoCloudSyncPreview(
            notepadTitle: resolvedTitle,
            notepadID: notepadID,
            action: action,
            candidateWords: candidateWords,
            wordsToAppend: appendedWords,
            historicalIndexHits: historicalIndexHits,
            skippedBatchDuplicates: parsed.skippedBatchDuplicates,
            skippedRemoteDuplicates: skippedRemote,
            parseFailures: parsed.failures,
            previewText: preview
        )
    }

    static func syncFromVaultToMomoCloud(
        vaultURL: URL,
        settings: MomoCloudSettings,
        preview: MomoCloudSyncPreview,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MomoCloudSyncResult {
        guard settings.canUseAPI else { throw MomoAPIError.missingToken }

        let store = MomoExportIndexStore(vaultURL: vaultURL, indexFileName: VaultSupportPaths.momoCloudSyncIndexFileName)
        var syncedIndex = try store.load()

        progress?(0.1, "正在连接墨墨开放 API…")
        let client = try MomoAPIClient(token: settings.trimmedToken)

        let action: String
        let notepadID: String
        let skippedRemote: Int
        let appendedWords: [String]
        var remoteWriteSucceeded = false
        var localIndexSaveSucceeded = false
        var localIndexSaveDetail = ""

        if let existingID = settings.trimmedSelectedNotepadID {
            progress?(0.35, "正在重新读取墨墨云词本…")
            let notepad = try await client.getNotepad(id: existingID)
            let merged = mergeMomoNotepadContent(existingContent: notepad.content, newWords: preview.candidateWords)
            skippedRemote = merged.skippedRemoteDuplicates
            appendedWords = merged.appendedWords
            notepadID = notepad.id

            if appendedWords.isEmpty {
                action = "未更新（墨墨云词本中已存在全部候选词）"
                remoteWriteSucceeded = true
            } else {
                progress?(0.7, "正在更新墨墨云词本…")
                _ = try await client.updateNotepad(notepad, content: merged.content)
                action = "更新已有云词本"
                remoteWriteSucceeded = true
            }
        } else {
            let merged = mergeMomoNotepadContent(existingContent: "", newWords: preview.candidateWords)
            skippedRemote = merged.skippedRemoteDuplicates
            appendedWords = merged.appendedWords
            if appendedWords.isEmpty {
                action = "未创建（没有可同步的新单词）"
                notepadID = "-"
                remoteWriteSucceeded = true
            } else {
                progress?(0.7, "正在创建墨墨云词本…")
                let created = try await client.createNotepad(title: settings.trimmedNotepadTitle, content: merged.content)
                action = "创建新云词本"
                notepadID = created.id
                remoteWriteSucceeded = true
            }
        }

        progress?(0.9, "正在保存本地同步索引…")
        if !appendedWords.isEmpty {
            for word in appendedWords {
                syncedIndex.insert(VocabClip.makeID(word: word))
            }
            do {
                try store.save(syncedIndex)
                localIndexSaveSucceeded = true
            } catch {
                localIndexSaveDetail = error.localizedDescription
            }
        } else {
            localIndexSaveSucceeded = true
        }

        let previewText = appendedWords.joined(separator: "\n") + (appendedWords.isEmpty ? "" : "\n")
        var summary = "墨墨云词本同步摘要\n"
        summary += "- 目标词本：\(preview.notepadTitle)\n"
        summary += "- 词本 ID：\(notepadID)\n"
        summary += "- 动作：\(action)\n"
        summary += "- 远端写入：\(remoteWriteSucceeded ? "成功" : "未完成")\n"
        summary += "- 本地同步索引：\(localIndexSaveSucceeded ? "成功" : "失败")\n"
        if !localIndexSaveDetail.isEmpty {
            summary += "  - 索引保存错误：\(localIndexSaveDetail)\n"
        }
        summary += "- 本次新增同步：\(appendedWords.count)\n"
        summary += "- 跳过重复：\(preview.skippedBatchDuplicates + skippedRemote)\n"
        summary += "  - Vault 内重复：\(preview.skippedBatchDuplicates)\n"
        summary += "  - 墨墨云词本已存在：\(skippedRemote)\n"
        summary += "- 本地历史命中（仅提示，不阻止补齐远端）：\(preview.historicalIndexHits)\n"
        summary += "- 解析失败：\(preview.parseFailures.count)\n"
        progress?(1.0, "墨墨云词本同步完成。")
        return MomoCloudSyncResult(
            summary: summary,
            previewText: previewText,
            appendedCount: appendedWords.count,
            historicalIndexHits: preview.historicalIndexHits,
            skippedBatchDuplicates: preview.skippedBatchDuplicates,
            skippedRemoteDuplicates: skippedRemote,
            localIndexSaveSucceeded: localIndexSaveSucceeded,
            parseFailures: preview.parseFailures
        )
    }

    // MARK: - CSV Export (Legacy)

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
        let words: [String]            // de-duped within a batch (CSV or vault scan)
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

    private static func parseVocabWordsFromVault(
        vaultURL: URL,
        preferences: PreferencesSnapshot,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> ParsedWords {
        let root = VaultUtilities.outputRootURL(vaultURL: vaultURL, preferences: preferences)
        let fm = FileManager.default

        var failures: [ParseFailure] = []
        var out: [String] = []
        var seen: Set<String> = []
        var skippedBatch = 0

        if !fm.fileExists(atPath: root.path) {
            failures.append(ParseFailure(fileName: VaultUtilities.relativePath(from: vaultURL, to: root), lineNumber: 0, reason: "输出目录不存在"))
            return ParsedWords(words: [], failures: failures, skippedBatchDuplicates: 0)
        }

        var files: [URL] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                if u.pathExtension.lowercased() != "md" { continue }
                files.append(u)
            }
        }
        files.sort { $0.path < $1.path }

        out.reserveCapacity(max(256, files.count * 8))
        seen.reserveCapacity(max(256, files.count * 8))

        func stripInlineAppComments(_ s: String) -> String {
            // Remove inline ID comments (both legacy HTML comments and current Obsidian comments).
            var t = s
            while let r0 = t.range(of: "<!--") {
                if let r1 = t.range(of: "-->", range: r0.lowerBound..<t.endIndex) {
                    t.removeSubrange(r0.lowerBound..<r1.upperBound)
                } else {
                    t = String(t[..<r0.lowerBound])
                    break
                }
            }
            while let r0 = t.range(of: "%%") {
                if let r1 = t.range(of: "%%", range: r0.upperBound..<t.endIndex) {
                    t.removeSubrange(r0.lowerBound..<r1.upperBound)
                } else {
                    t = String(t[..<r0.lowerBound])
                    break
                }
            }
            return t
        }

        func stripTrailingAppTags(_ s: String) -> String {
            var t = s.oeiTrimmed()
            while true {
                if t.hasSuffix(" #wrong") {
                    t = String(t.dropLast(" #wrong".count)).oeiTrimmed()
                    continue
                }
                if t.hasSuffix(" #mastered") {
                    t = String(t.dropLast(" #mastered".count)).oeiTrimmed()
                    continue
                }
                break
            }
            return t
        }

        func stripTrailingPhoneticIfPresent(_ s: String) -> String {
            // Vocab head is often: "word  /phonetic/"
            // (two spaces before '/', stable from our renderer)
            let t = s.oeiTrimmed()
            guard t.hasSuffix("/") else { return t }
            if let r = t.range(of: "  /", options: .backwards) {
                return String(t[..<r.lowerBound]).oeiTrimmed()
            }
            return t
        }

        func extractHeadText(_ rawLine: String) -> String? {
            let t = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("- [") else { return nil }
            guard let r = t.range(of: "] ") else { return nil }
            let rest = t[r.upperBound...]
            var head = stripInlineAppComments(String(rest))
            head = stripTrailingAppTags(head)
            head = stripTrailingPhoneticIfPresent(head)
            return head.oeiTrimmed()
        }

        let totalFiles = files.count
        for (fileIdx, fileURL) in files.enumerated() {
            progress?(Double(fileIdx) / Double(max(totalFiles, 1)))

            let rel = VaultUtilities.relativePath(from: vaultURL, to: fileURL)
            guard let text = VaultUtilities.readTextFileLossy(fileURL) else {
                failures.append(ParseFailure(fileName: rel, lineNumber: 0, reason: "无法读取 Markdown（编码未知）"))
                continue
            }

            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")

            var i = 0
            while i < lines.count {
                let raw = lines[i]
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("- [") else {
                    i += 1
                    continue
                }

                let start = i
                var block: [String] = [raw]
                i += 1
                while i < lines.count {
                    let t2 = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if t2.hasPrefix("- [") || t2.hasPrefix("## ") {
                        break
                    }
                    block.append(lines[i])
                    i += 1
                }

                // Detect vocabulary blocks by metadata lines. This avoids exporting sentence clips.
                var isVocab = false
                var sawChinese = false
                for l in block {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- 释义：") {
                        isVocab = true
                        break
                    }
                    if t.hasPrefix("- 中文：") {
                        sawChinese = true
                    }
                }
                if !isVocab, sawChinese {
                    continue
                }
                if !isVocab {
                    // Fallback by id markers (older layouts / malformed blocks).
                    let blockText = block.joined(separator: "\n")
                    if blockText.contains("vocab_") {
                        isVocab = true
                    } else {
                        continue
                    }
                }

                guard let head = extractHeadText(lines[start]), !head.isEmpty else {
                    failures.append(ParseFailure(fileName: rel, lineNumber: start + 1, reason: "无法解析单词（head 行）"))
                    continue
                }

                let id = VocabClip.makeID(word: head)
                if seen.contains(id) {
                    skippedBatch += 1
                    continue
                }
                seen.insert(id)
                out.append(head)
            }
        }

        progress?(1.0)
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
