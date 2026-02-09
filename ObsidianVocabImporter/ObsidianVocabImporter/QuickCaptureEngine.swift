import Foundation

enum QuickCaptureKind: String, CaseIterable, Identifiable, Sendable {
    case vocabulary
    case sentence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vocabulary: return "词汇"
        case .sentence: return "句子"
        }
    }
}

struct QuickCaptureInput: Sendable {
    let kind: QuickCaptureKind
    let text: String
    let translation: String
    let source: String
    let dateYMD: String
}

enum QuickCaptureOutcome: Sendable {
    case added
    case skippedIndexDuplicate
    case skippedFileDuplicate
}

struct QuickCaptureResult: Sendable {
    let outcome: QuickCaptureOutcome
    let message: String
    let outputURL: URL
    let relativeOutputPath: String
    let id: String
}

enum QuickCaptureEngine {
    private static func sanitizeVocabWordForCapture(_ raw: String) -> String {
        // Quick-capture often comes from subtitles/clipboard with trailing punctuation, quotes, etc.
        // We only strip *surrounding* punctuation so we keep internal characters like "can't" or "co-operate".
        var s = raw.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        if s.isEmpty { return s }

        // Remove common surrounding wrappers/punctuation repeatedly.
        // Intentionally *not* stripping generic `.symbols` because it would break words like "C++" / "C#".
        let wrappers: Set<Character> = [
            "\"", "'", "“", "”", "‘", "’",
            "(", ")", "[", "]", "{", "}", "<", ">",
            "（", "）", "【", "】", "「", "」", "『", "』", "《", "》",
            ",", ".", "!", "?", ":", ";",
            "，", "。", "！", "？", "：", "；",
            "…", "—", "–", "-", "·"
        ]

        while let first = s.first, wrappers.contains(first) {
            s.removeFirst()
            s = s.oeiTrimmed()
        }
        while let last = s.last, wrappers.contains(last) {
            s.removeLast()
            s = s.oeiTrimmed()
        }

        return s.oeiCompressWhitespaceToSingleSpaces()
    }

    static func capture(
        input: QuickCaptureInput,
        vaultURL: URL,
        preferences: PreferencesSnapshot
    ) throws -> QuickCaptureResult {
        let fm = FileManager.default

        let outputURL = VaultUtilities.dailyReviewFileURL(vaultURL: vaultURL, preferences: preferences, dateYMD: input.dateYMD)
        let relPath = VaultUtilities.relativePath(from: vaultURL, to: outputURL)

        // Load dedup index (primary + legacy).
        let indexStore = ImportedIndexStore(vaultURL: vaultURL)
        var index = try indexStore.load()

        // Best-effort self-heal: scan output Markdown if the index is missing or likely incomplete.
        // This mirrors the ImportPlanner behavior, but keeps it lightweight for quick captures.
        let outputRoot = VaultUtilities.outputRootURL(vaultURL: vaultURL, preferences: preferences)

        let primaryIndexExists = fm.fileExists(atPath: indexStore.indexURL.path)
        let legacyIndexExists = fm.fileExists(atPath: indexStore.legacyIndexURL.path)

        // If we only have the legacy index file, we still want to persist the merged sets to the primary
        // location at least once so future builds can rely on the primary index alone.
        var shouldPersistIndexBeforeEarlyReturn = (!primaryIndexExists && legacyIndexExists)
        var indexUpdatedByScan = false
        var outputIsDir: ObjCBool = false
        if fm.fileExists(atPath: outputRoot.path, isDirectory: &outputIsDir), outputIsDir.boolValue {
            let sampleLimit = 24

            func enumerateMarkdownFiles(limit: Int?) -> [URL] {
                var urls: [URL] = []
                if let e = fm.enumerator(at: outputRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let u as URL in e {
                        if u.pathExtension.lowercased() != "md" { continue }
                        urls.append(u)
                        if let limit, urls.count >= limit { break }
                    }
                }
                return urls
            }

            func scanFiles(_ files: [URL], into sentences: inout Set<String>, _ vocab: inout Set<String>) {
                for u in files {
                    guard let text = VaultUtilities.readTextFileLossy(u) else { continue }
                    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    let (sids, vids) = MarkdownUpdater.extractIDs(from: normalized)
                    sentences.formUnion(sids)
                    vocab.formUnion(vids)
                }
            }

            var needsFullScan = false
            if !primaryIndexExists {
                needsFullScan = true
                if legacyIndexExists {
                    var sampleS: Set<String> = []
                    var sampleV: Set<String> = []
                    scanFiles(enumerateMarkdownFiles(limit: sampleLimit), into: &sampleS, &sampleV)
                    if sampleS.subtracting(index.sentences).isEmpty, sampleV.subtracting(index.vocab).isEmpty {
                        needsFullScan = false
                    }
                }
            } else {
                var sampleS: Set<String> = []
                var sampleV: Set<String> = []
                scanFiles(enumerateMarkdownFiles(limit: sampleLimit), into: &sampleS, &sampleV)
                if !sampleS.subtracting(index.sentences).isEmpty || !sampleV.subtracting(index.vocab).isEmpty {
                    needsFullScan = true
                }
            }

            if needsFullScan {
                let beforeS = index.sentences.count
                let beforeV = index.vocab.count

                var scannedS: Set<String> = []
                var scannedV: Set<String> = []
                scannedS.reserveCapacity(1024)
                scannedV.reserveCapacity(1024)

                if let e = fm.enumerator(at: outputRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let u as URL in e {
                        if u.pathExtension.lowercased() != "md" { continue }
                        guard let text = VaultUtilities.readTextFileLossy(u) else { continue }
                        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                        let (sids, vids) = MarkdownUpdater.extractIDs(from: normalized)
                        scannedS.formUnion(sids)
                        scannedV.formUnion(vids)
                    }
                }

                index.sentences.formUnion(scannedS)
                index.vocab.formUnion(scannedV)
                indexUpdatedByScan = (index.sentences.count != beforeS) || (index.vocab.count != beforeV)
                if indexUpdatedByScan {
                    shouldPersistIndexBeforeEarlyReturn = true
                }
            }
        }

        let rawText = input.text.oeiTrimmed()
        if rawText.isEmpty {
            throw NSError(domain: "OEI", code: 801, userInfo: [NSLocalizedDescriptionKey: "内容为空。"])
        }

        let id: String
        var newSentences: [SentenceClip] = []
        var newVocab: [VocabClip] = []

        switch input.kind {
        case .vocabulary:
            let cleanedWord = sanitizeVocabWordForCapture(rawText)
            if cleanedWord.isEmpty {
                throw NSError(domain: "OEI", code: 801, userInfo: [NSLocalizedDescriptionKey: "内容为空。"])
            }

            id = VocabClip.makeID(word: cleanedWord)
            if index.vocab.contains(id) {
                if shouldPersistIndexBeforeEarlyReturn {
                    // Best-effort persist of self-heal / legacy promotion even when the capture is a no-op.
                    try? indexStore.save(index)
                }
                return QuickCaptureResult(outcome: .skippedIndexDuplicate, message: "已存在（历史索引查重）：\(cleanedWord)", outputURL: outputURL, relativeOutputPath: relPath, id: id)
            }
            newVocab = [
                VocabClip(
                    id: id,
                    word: cleanedWord,
                    phonetic: nil,
                    translation: input.translation,
                    date: input.dateYMD
                )
            ]

        case .sentence:
            let sourceField = input.source.oeiTrimmed()
            let sourceOrNil = sourceField.isEmpty ? nil : sourceField
            id = SentenceClip.makeID(sentence: rawText, url: sourceOrNil)
            if index.sentences.contains(id) {
                if shouldPersistIndexBeforeEarlyReturn {
                    // Best-effort persist of self-heal / legacy promotion even when the capture is a no-op.
                    try? indexStore.save(index)
                }
                return QuickCaptureResult(outcome: .skippedIndexDuplicate, message: "已存在（历史索引查重）：\(rawText)", outputURL: outputURL, relativeOutputPath: relPath, id: id)
            }
            newSentences = [
                SentenceClip(
                    id: id,
                    sentence: rawText,
                    translation: input.translation,
                    url: sourceOrNil,
                    date: input.dateYMD
                )
            ]
        }

        // Read existing markdown (if any).
        let existing: String?
        if fm.fileExists(atPath: outputURL.path) {
            existing = VaultUtilities.readTextFileLossy(outputURL)
            if existing == nil {
                throw NSError(domain: "OEI", code: 802, userInfo: [NSLocalizedDescriptionKey: "无法读取现有 Markdown（编码未知）：\(relPath)"])
            }
        } else {
            existing = nil
        }
        let existingNormalized = existing?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        let update = MarkdownUpdater.update(
            existing: existingNormalized,
            date: input.dateYMD,
            mode: .merged,
            newSentences: newSentences,
            newVocab: newVocab,
            preferences: preferences
        )

        let updatedNormalized = update.updatedMarkdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let shouldWrite: Bool
        if let existingNormalized {
            shouldWrite = updatedNormalized != existingNormalized
        } else {
            // Only create a new file when we actually have new entries.
            shouldWrite = !update.appendedSentences.isEmpty || !update.appendedVocab.isEmpty
        }

        if shouldWrite {
            try AtomicFileWriter.writeString(update.updatedMarkdown, to: outputURL)
        }

        // Keep index consistent with what's on disk (and self-heal if it was incomplete).
        let (sids, vids) = MarkdownUpdater.extractIDs(from: updatedNormalized)
        index.sentences.formUnion(sids)
        index.vocab.formUnion(vids)
        try indexStore.save(index)

        if update.appendedSentences.isEmpty && update.appendedVocab.isEmpty {
            return QuickCaptureResult(outcome: .skippedFileDuplicate, message: "已存在（文件内查重）：\(rawText)", outputURL: outputURL, relativeOutputPath: relPath, id: id)
        }

        return QuickCaptureResult(outcome: .added, message: "已写入：\(relPath)", outputURL: outputURL, relativeOutputPath: relPath, id: id)
    }

    static func markWrongOnce(
        id: String,
        dateYMD: String,
        vaultURL: URL,
        preferences: PreferencesSnapshot
    ) throws -> Bool {
        let url = VaultUtilities.dailyReviewFileURL(vaultURL: vaultURL, preferences: preferences, dateYMD: dateYMD)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let text = VaultUtilities.readTextFileLossy(url) else {
            throw NSError(domain: "OEI", code: 811, userInfo: [NSLocalizedDescriptionKey: "无法读取 Markdown（编码未知）：\(url.path)"])
        }

        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")

        func isEntryHeadLine(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("- [")
        }

        for i in 0..<lines.count {
            if !lines[i].contains(id) { continue }

            // Find the entry head line that owns this id line, and ensure the id is inside that block
            // before tagging. This prevents accidental tagging when the file was manually edited.
            var headIdx: Int? = nil
            var j = i
            while j >= 0 {
                if isEntryHeadLine(lines[j]) {
                    headIdx = j
                    break
                }
                j -= 1
            }
            guard let head = headIdx else { continue }

            var end = head + 1
            while end < lines.count {
                let t = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("- [") || t.hasPrefix("## ") {
                    break
                }
                end += 1
            }

            var ownsID = false
            if head < end {
                for k in head..<end where lines[k].contains(id) {
                    ownsID = true
                    break
                }
            }
            guard ownsID else { continue }

            if lines[head].contains("#wrong") { return false }
            lines[head] += " #wrong"

            var out = lines.joined(separator: "\n")
            if !out.hasSuffix("\n") { out += "\n" }
            try AtomicFileWriter.writeString(out, to: url)
            return true
        }

        return false
    }
}
