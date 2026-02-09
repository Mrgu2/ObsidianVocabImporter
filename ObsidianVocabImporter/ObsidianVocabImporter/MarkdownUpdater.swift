import Foundation

struct MarkdownUpdateResult: Sendable {
    let updatedMarkdown: String
    let appendedSentences: [SentenceClip]
    let appendedVocab: [VocabClip]
    let totalSentenceCount: Int
    let totalVocabCount: Int

    // Moved due to auto-archive (checked -> Mastered). Only counts blocks we actually moved.
    let movedMasteredSentenceIDs: [String]
    let movedMasteredVocabIDs: [String]
}

struct MarkdownArchiveResult: Sendable {
    let updatedMarkdown: String
    let movedSentenceIDs: [String]
    let movedVocabIDs: [String]
}

struct MarkdownUpdater {
    // Markdown files are user-facing, so we keep the format stable and easy to scan.
    // We also make updates deterministic so repeated imports are predictable.
    static func update(
        existing: String?,
        date: String,
        mode: ImportMode,
        newSentences: [SentenceClip],
        newVocab: [VocabClip],
        preferences: PreferencesSnapshot
    ) -> MarkdownUpdateResult {
        let normalizedExisting = existing?.oeiNormalizeLineEndings()
        let (existingSentIDs, existingVocabIDs) = extractIDs(from: normalizedExisting ?? "")

        let filteredSentences = newSentences.filter { !existingSentIDs.contains($0.id) }
        let filteredVocab = newVocab.filter { !existingVocabIDs.contains($0.id) }

        var lines: [String] = normalizedExisting?.components(separatedBy: "\n") ?? []

        // 1) Frontmatter: preserve unknown keys but ensure our required keys exist.
        lines = upsertFrontmatter(lines: lines, date: date)

        // 2) Ensure overview line exists (we rewrite it at the end with correct totals).
        let overviewIndex = upsertOverviewPlaceholder(lines: &lines)

        // 3) Layout normalization (merged-mode strategies can migrate between sectioned/interleaved).
        normalizeLayout(lines: &lines, mode: mode, preferences: preferences)

        // 4) Auto-archive: move checked blocks into Mastered sections (optional).
        var movedS: [String] = []
        var movedV: [String] = []
        if preferences.autoArchiveMastered {
            let moved = archiveMasteredInPlace(lines: &lines, addMasteredTag: preferences.addMasteredTag)
            movedS = moved.movedSentenceIDs
            movedV = moved.movedVocabIDs
        }

        // Derive vocabulary tokens from the whole note (existing + newly appended vocab).
        // This lets "highlight vocab in sentences" work even when today's vocab isn't newly imported.
        let tokenMap: HighlightTokenMap
        if mode == .merged {
            tokenMap = makeHighlightTokenMap(existingLines: lines, newVocab: filteredVocab)
        } else {
            tokenMap = HighlightTokenMap(tokenToDisplay: [:], tokenSet: [])
        }
        let highlightTokenSet = (mode == .merged && preferences.highlightVocabInSentences) ? tokenMap.tokenSet : []

        // Update existing sentence blocks in-place so the note stays consistent across multiple imports.
        // This is best-effort and idempotent (we avoid double-bolding).
        if mode == .merged, !highlightTokenSet.isEmpty {
            applySentenceHighlightInPlace(lines: &lines, tokenSet: highlightTokenSet)
        }
        if mode == .merged, preferences.mergedLayoutStrategy == .sentencePrimary {
            upsertRelatedWordsInPlace(lines: &lines, tokenToDisplay: tokenMap.tokenToDisplay)
        }

        // 5) Append new items.
        let wantVocab = (mode == .vocabulary || mode == .merged)
        let wantSentences = (mode == .sentences || mode == .merged)

        if mode == .merged, preferences.mergedLayoutStrategy == .interleaved {
            let interleaved = renderInterleavedEntries(
                vocab: filteredVocab,
                sentences: filteredSentences,
                highlightTokenSet: highlightTokenSet,
                includeRelatedWords: false,
                relatedWordMap: tokenMap.tokenToDisplay
            )
            append(toSection: "## Review", entryLines: interleaved, lines: &lines)
        } else {
            // Sectioned layout.
            if wantVocab {
                let vocabLines = filteredVocab.flatMap { renderVocabEntry($0) }
                append(toSection: "## Vocabulary", entryLines: vocabLines, lines: &lines)
            }

            if wantSentences {
                let sentenceLines: [String]
                if mode == .merged, preferences.mergedLayoutStrategy == .sentencePrimary {
                    sentenceLines = filteredSentences.flatMap {
                        let related = relatedWords(in: $0.sentence, tokenToDisplay: tokenMap.tokenToDisplay)
                        return renderSentenceEntry($0, highlightTokenSet: highlightTokenSet, relatedWords: related)
                    }
                } else {
                    sentenceLines = filteredSentences.flatMap {
                        renderSentenceEntry($0, highlightTokenSet: highlightTokenSet, relatedWords: [])
                    }
                }
                append(toSection: "## Sentences", entryLines: sentenceLines, lines: &lines)
            }
        }

        // 6) Update overview with totals after write.
        let counts = computeOverviewCounts(lines: lines)
        let overviewLine = renderOverviewLine(counts)
        if overviewIndex < lines.count {
            lines[overviewIndex] = overviewLine
        }

        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") {
            out += "\n"
        }

        return MarkdownUpdateResult(
            updatedMarkdown: out,
            appendedSentences: filteredSentences,
            appendedVocab: filteredVocab,
            totalSentenceCount: counts.activeSentences,
            totalVocabCount: counts.activeVocab,
            movedMasteredSentenceIDs: movedS,
            movedMasteredVocabIDs: movedV
        )
    }

    // Scan-only helper (no appending): archive checked entries into Mastered sections.
    static func archiveMastered(existing: String, preferences: PreferencesSnapshot) -> MarkdownArchiveResult {
        var lines = existing.oeiNormalizeLineEndings().components(separatedBy: "\n")
        let moved = archiveMasteredInPlace(lines: &lines, addMasteredTag: preferences.addMasteredTag)

        // Keep overview counts in sync after moving items.
        let overviewIndex = upsertOverviewPlaceholder(lines: &lines)
        let counts = computeOverviewCounts(lines: lines)
        if overviewIndex < lines.count {
            lines[overviewIndex] = renderOverviewLine(counts)
        }

        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") {
            out += "\n"
        }
        return MarkdownArchiveResult(updatedMarkdown: out, movedSentenceIDs: moved.movedSentenceIDs, movedVocabIDs: moved.movedVocabIDs)
    }

    // MARK: - Frontmatter / Overview

    private struct OverviewCounts: Sendable {
        let activeSentences: Int
        let activeVocab: Int
        let masteredSentences: Int
        let masteredVocab: Int
    }

    private enum SectionKind: Sendable {
        case none
        case activeVocab
        case activeSentences
        case activeReview
        case masteredVocab
        case masteredSentences
    }

    private static func computeOverviewCounts(lines: [String]) -> OverviewCounts {
        var activeS: Set<String> = []
        var activeV: Set<String> = []
        var masteredS: Set<String> = []
        var masteredV: Set<String> = []

        activeS.reserveCapacity(128)
        activeV.reserveCapacity(128)
        masteredS.reserveCapacity(64)
        masteredV.reserveCapacity(64)

        var section: SectionKind = .none
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("## ") {
                switch t {
                case "## Vocabulary":
                    section = .activeVocab
                case "## Sentences":
                    section = .activeSentences
                case "## Review":
                    section = .activeReview
                case "## Mastered Vocabulary":
                    section = .masteredVocab
                case "## Mastered Sentences":
                    section = .masteredSentences
                default:
                    section = .none
                }
                continue
            }

            guard section != .none else { continue }

            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)

            switch section {
            case .activeVocab:
                for m in vocabRegex.matches(in: raw, options: [], range: range) {
                    activeV.insert(ns.substring(with: m.range))
                }
            case .activeSentences:
                for m in sentRegex.matches(in: raw, options: [], range: range) {
                    activeS.insert(ns.substring(with: m.range))
                }
            case .activeReview:
                for m in vocabRegex.matches(in: raw, options: [], range: range) {
                    activeV.insert(ns.substring(with: m.range))
                }
                for m in sentRegex.matches(in: raw, options: [], range: range) {
                    activeS.insert(ns.substring(with: m.range))
                }
            case .masteredVocab:
                for m in vocabRegex.matches(in: raw, options: [], range: range) {
                    masteredV.insert(ns.substring(with: m.range))
                }
            case .masteredSentences:
                for m in sentRegex.matches(in: raw, options: [], range: range) {
                    masteredS.insert(ns.substring(with: m.range))
                }
            case .none:
                break
            }
        }

        return OverviewCounts(
            activeSentences: activeS.count,
            activeVocab: activeV.count,
            masteredSentences: masteredS.count,
            masteredVocab: masteredV.count
        )
    }

    private static func renderOverviewLine(_ counts: OverviewCounts) -> String {
        var vocabPart = "Vocabulary: \(counts.activeVocab)"
        if counts.masteredVocab > 0 {
            vocabPart += " (Mastered \(counts.masteredVocab))"
        }

        var sentPart = "Sentences: \(counts.activeSentences)"
        if counts.masteredSentences > 0 {
            sentPart += " (Mastered \(counts.masteredSentences))"
        }

        return "**Overview:** \(vocabPart) | \(sentPart)"
    }

    private static func upsertFrontmatter(lines: [String], date: String) -> [String] {
        guard !lines.isEmpty else {
            return canonicalFrontmatterLines(date: date)
        }

        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            let fmBody = Array(lines[1..<end])
            let rest: [String]
            let restStart = end + 1
            if restStart < lines.count {
                rest = Array(lines[restStart...])
            } else {
                rest = []
            }
            let updatedBody = upsertFrontmatterBody(fmBody, date: date)
            return ["---"] + updatedBody + ["---", ""] + rest
        }

        // No frontmatter detected.
        return canonicalFrontmatterLines(date: date) + lines
    }

    private static func canonicalFrontmatterLines(date: String) -> [String] {
        [
            "---",
            "date: \(date)",
            "source: imported",
            "tags: [english, review]",
            "---",
            ""
        ]
    }

    private static func upsertFrontmatterBody(_ body: [String], date: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(body.count + 3)

        var seenDate = false
        var seenSource = false
        var seenTags = false

        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("date:") {
                out.append("date: \(date)")
                seenDate = true
                continue
            }
            if lower.hasPrefix("source:") {
                out.append("source: imported")
                seenSource = true
                continue
            }
            if lower.hasPrefix("tags:") {
                out.append(upsertTagsLine(original: line))
                seenTags = true
                continue
            }

            out.append(line)
        }

        if !seenDate { out.append("date: \(date)") }
        if !seenSource { out.append("source: imported") }
        if !seenTags { out.append("tags: [english, review]") }

        return out
    }

    private static func upsertTagsLine(original: String) -> String {
        // Best-effort merge: keep existing tags if they are in bracket form, and ensure english/review exist.
        // If parsing fails, fall back to the canonical tags line.
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else {
            return "tags: [english, review]"
        }

        let rhs = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard rhs.hasPrefix("["), rhs.contains("]") else {
            // Unknown YAML form (e.g. multiline list). Keep it untouched to avoid destructive edits.
            return original
        }

        guard let close = rhs.lastIndex(of: "]") else { return original }
        let inner = rhs[rhs.index(after: rhs.startIndex)..<close]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        func stripQuotes(_ s: String) -> String {
            var t = s
            if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
                t = String(t.dropFirst().dropLast())
            }
            return t
        }

        var set: Set<String> = Set(parts.map { stripQuotes($0) })
        set.insert("english")
        set.insert("review")

        let rendered = set.sorted().joined(separator: ", ")
        return "tags: [\(rendered)]"
    }

    private static func upsertOverviewPlaceholder(lines: inout [String]) -> Int {
        func canonicalInsertIndex(_ lines: [String]) -> Int {
            // Right after frontmatter, skipping blank lines.
            var i = 0
            if !lines.isEmpty, lines[0] == "---" {
                i = 1
                while i < lines.count {
                    if lines[i] == "---" {
                        i += 1
                        break
                    }
                    i += 1
                }
            }
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                i += 1
            }
            return i
        }

        // If the user manually moved/duplicated the overview line, keep the file tidy:
        // - remove all existing "**Overview:**" lines
        // - re-insert exactly one at the canonical position.
        let existing = lines.enumerated().compactMap { idx, line in
            line.hasPrefix("**Overview:**") ? idx : nil
        }
        if !existing.isEmpty {
            for idx in existing.reversed() { lines.remove(at: idx) }
        }

        let i = canonicalInsertIndex(lines)
        lines.insert("**Overview:** Vocabulary: 0 | Sentences: 0", at: i)
        lines.insert("", at: i + 1)
        return i
    }

    // MARK: - Layout

    private static func normalizeLayout(lines: inout [String], mode: ImportMode, preferences: PreferencesSnapshot) {
        guard mode == .merged else {
            // For single-mode files, just ensure the expected section exists.
            switch mode {
            case .sentences:
                ensureHeadingExists("## Sentences", lines: &lines)
            case .vocabulary:
                ensureHeadingExists("## Vocabulary", lines: &lines)
            case .merged:
                break
            }
            return
        }

        let strategy = preferences.mergedLayoutStrategy
        switch strategy {
        case .interleaved:
            ensureHeadingExists("## Review", lines: &lines)

            // Migrate sectioned files into interleaved "Review" section (best-effort).
            if let vocab = extractAndRemoveSection("## Vocabulary", lines: &lines) {
                append(toSection: "## Review", entryLines: vocab, lines: &lines)
            }
            if let sent = extractAndRemoveSection("## Sentences", lines: &lines) {
                append(toSection: "## Review", entryLines: sent, lines: &lines)
            }

        case .vocabThenSentences:
            migrateReviewToSectionedIfNeeded(lines: &lines)
            ensureSectionOrder(first: "## Vocabulary", second: "## Sentences", lines: &lines)

        case .sentencePrimary:
            migrateReviewToSectionedIfNeeded(lines: &lines)
            ensureSectionOrder(first: "## Sentences", second: "## Vocabulary", lines: &lines)
        }
    }

    private static func migrateReviewToSectionedIfNeeded(lines: inout [String]) {
        guard let review = extractAndRemoveSection("## Review", lines: &lines) else { return }
        let blocks = splitIntoEntryBlocks(review)
        var vocabLines: [String] = []
        var sentLines: [String] = []
        vocabLines.reserveCapacity(review.count)
        sentLines.reserveCapacity(review.count)

        for b in blocks {
            if b.kind == .vocab {
                vocabLines.append(contentsOf: b.lines)
            } else if b.kind == .sentence {
                sentLines.append(contentsOf: b.lines)
            } else {
                // Unknown block: keep it in sentences section by default.
                sentLines.append(contentsOf: b.lines)
            }
            // Preserve original spacing between blocks.
            if !b.lines.isEmpty, !b.lines.last!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // no-op
            }
        }

        if !vocabLines.isEmpty {
            append(toSection: "## Vocabulary", entryLines: vocabLines, lines: &lines)
        }
        if !sentLines.isEmpty {
            append(toSection: "## Sentences", entryLines: sentLines, lines: &lines)
        }
    }

    private static func ensureSectionOrder(first: String, second: String, lines: inout [String]) {
        ensureHeadingExists(first, lines: &lines)
        ensureHeadingExists(second, lines: &lines)

        guard let a = headingIndex(first, lines: lines),
              let b = headingIndex(second, lines: lines) else { return }

        if a < b { return }

        // Move the `first` section block before the `second` section block.
        // We only move our own headings; other user content stays where it is.
        let aEnd = endOfSection(startingAt: a, lines: lines)
        let firstBlock = Array(lines[a..<aEnd])
        lines.removeSubrange(a..<aEnd)

        if let b2 = headingIndex(second, lines: lines) {
            lines.insert(contentsOf: firstBlock, at: b2)
        }
    }

    private static func ensureHeadingExists(_ heading: String, lines: inout [String]) {
        guard headingIndex(heading, lines: lines) == nil else { return }

        // Keep "Mastered" sections at the end, so newly-created active sections don't appear after them.
        // This matters when users switch layout strategies or manually edit headings.
        let isMastered = heading.hasPrefix("## Mastered ")
        let insertionIndex: Int
        if isMastered {
            insertionIndex = lines.count
        } else if let firstMastered = lines.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return t == "## Mastered Vocabulary" || t == "## Mastered Sentences"
        }) {
            insertionIndex = firstMastered
        } else {
            insertionIndex = lines.count
        }

        var i = insertionIndex
        if i > 0, !lines[i - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.insert("", at: i)
            i += 1
        }

        lines.insert(heading, at: i)
        i += 1

        // Ensure a blank line after the heading for readability and stable parsing.
        if i >= lines.count || !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.insert("", at: i)
        }
    }

    private static func extractAndRemoveSection(_ heading: String, lines: inout [String]) -> [String]? {
        guard let h = headingIndex(heading, lines: lines) else { return nil }
        let end = endOfSection(startingAt: h, lines: lines)
        let content = Array(lines[(h + 1)..<end])
        lines.removeSubrange(h..<end)

        // Remove one leading blank line if it became duplicated after removal.
        if h > 0, h - 1 < lines.count {
            if lines[h - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               h < lines.count,
               lines[h].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.remove(at: h)
            }
        }

        return content
    }

    // MARK: - Mastered Archiving

    private enum BlockKind: Sendable {
        case sentence
        case vocab
        case unknown
    }

    private struct EntryBlock: Sendable {
        let kind: BlockKind
        let id: String?
        let isChecked: Bool
        var lines: [String]
    }

    private static func archiveMasteredInPlace(lines: inout [String], addMasteredTag: Bool) -> (movedSentenceIDs: [String], movedVocabIDs: [String]) {
        // We only move checked blocks from the "active" sections:
        // - Sectioned layout: ## Vocabulary / ## Sentences
        // - Interleaved layout: ## Review
        let activeHeadings = ["## Vocabulary", "## Sentences", "## Review"]
        var movedV: [String] = []
        var movedS: [String] = []

        // Collect blocks to move and remove them from the active sections.
        var vocabBlocks: [[String]] = []
        var sentBlocks: [[String]] = []

        for heading in activeHeadings {
            guard let h = headingIndex(heading, lines: lines) else { continue }
            let end = endOfSection(startingAt: h, lines: lines)
            if h + 1 >= end { continue }

            let sectionRange = (h + 1)..<end
            let sectionLines = Array(lines[sectionRange])
            let blocks = splitIntoEntryBlocks(sectionLines)

            // Rebuild section content, skipping checked blocks.
            var rebuilt: [String] = []
            rebuilt.reserveCapacity(sectionLines.count)

            for b in blocks {
                if b.isChecked {
                    var movedLines = b.lines
                    if addMasteredTag, !movedLines.isEmpty {
                        movedLines[0] = ensureMasteredTag(on: movedLines[0])
                    }

                    switch b.kind {
                    case .vocab:
                        vocabBlocks.append(movedLines)
                        if let id = b.id { movedV.append(id) }
                    case .sentence:
                        sentBlocks.append(movedLines)
                        if let id = b.id { movedS.append(id) }
                    case .unknown:
                        // If the ID line was manually removed, fall back to the current section's meaning.
                        // We never infer in the mixed "Review" section to avoid moving unrelated checklists.
                        if heading == "## Vocabulary" {
                            vocabBlocks.append(movedLines)
                        } else if heading == "## Sentences" {
                            sentBlocks.append(movedLines)
                        } else {
                            rebuilt.append(contentsOf: b.lines)
                        }
                    }
                } else {
                    rebuilt.append(contentsOf: b.lines)
                }
            }

            // Replace section content in the original lines array.
            lines.replaceSubrange(sectionRange, with: rebuilt)
        }

        // Append moved blocks to Mastered sections.
        if !vocabBlocks.isEmpty {
            let flat = vocabBlocks.flatMap { $0 + [""] }
            append(toSection: "## Mastered Vocabulary", entryLines: flat, lines: &lines)
        }
        if !sentBlocks.isEmpty {
            let flat = sentBlocks.flatMap { $0 + [""] }
            append(toSection: "## Mastered Sentences", entryLines: flat, lines: &lines)
        }

        return (movedS, movedV)
    }

    private static func ensureMasteredTag(on line: String) -> String {
        if line.contains("#mastered") { return line }
        return line + " #mastered"
    }

    // MARK: - Entry Block Splitting

    private static func splitIntoEntryBlocks(_ sectionLines: [String]) -> [EntryBlock] {
        var blocks: [EntryBlock] = []
        blocks.reserveCapacity(max(8, sectionLines.count / 3))

        var i = 0
        while i < sectionLines.count {
            let line = sectionLines[i]
            if line.hasPrefix("- [") {
                let start = i
                i += 1
                while i < sectionLines.count {
                    let next = sectionLines[i]
                    if next.hasPrefix("- [") || next.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ") {
                        break
                    }
                    i += 1
                }
                let blockLines = Array(sectionLines[start..<i])
                let parsed = parseEntryBlock(blockLines)
                blocks.append(parsed)
            } else {
                // Non-entry lines are kept as a "block" to preserve content inside sections.
                blocks.append(EntryBlock(kind: .unknown, id: nil, isChecked: false, lines: [line]))
                i += 1
            }
        }

        return blocks
    }

    private static let vocabIDRegex = try! NSRegularExpression(pattern: "\\bvocab_[0-9a-f]{40}\\b", options: [])
    private static let sentIDRegex = try! NSRegularExpression(pattern: "\\bsent_[0-9a-f]{40}\\b", options: [])

    private static func parseEntryBlock(_ lines: [String]) -> EntryBlock {
        let isChecked: Bool
        if let first = lines.first {
            isChecked = first.lowercased().hasPrefix("- [x]")
        } else {
            isChecked = false
        }

        let text = lines.joined(separator: "\n")
        let ns = text as NSString

        if let m = vocabIDRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range)
            return EntryBlock(kind: .vocab, id: id, isChecked: isChecked, lines: lines)
        }
        if let m = sentIDRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range)
            return EntryBlock(kind: .sentence, id: id, isChecked: isChecked, lines: lines)
        }

        return EntryBlock(kind: .unknown, id: nil, isChecked: isChecked, lines: lines)
    }

    // MARK: - Rendering

    private static func renderVocabEntry(_ v: VocabClip) -> [String] {
        let word = v.word.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        let translation = v.translation.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()

        let head: String
        if let p = v.phonetic?.oeiTrimmed(), !p.isEmpty {
            // Exported phonetics often already include surrounding slashes, e.g. "/əˈbɜːv/".
            // Normalize to exactly one pair of slashes in the Markdown output.
            let core = p
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .oeiStrippingSurroundingSlashes()
            head = core.isEmpty ? "- [ ] \(word)" : "- [ ] \(word)  /\(core)/"
        } else {
            head = "- [ ] \(word)"
        }

        return [
            head,
            "  - \u{91ca}\u{4e49}\u{ff1a}\(translation)", // 释义：
            "  - id: \(v.id)"
        ]
    }

    private static func renderSentenceEntry(_ s: SentenceClip, highlightTokenSet: Set<String>, relatedWords: [String]) -> [String] {
        let rawSentence = s.sentence.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        let sentence = highlightTokenSet.isEmpty ? rawSentence : boldKeywords(in: rawSentence, tokenSet: highlightTokenSet)
        let translation = s.translation.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()

        var out: [String] = []
        out.reserveCapacity(6)
        out.append("- [ ] \(sentence)")
        out.append("  - \u{4e2d}\u{6587}\u{ff1a}\(translation)") // 中文：
        if let url = s.url?.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces(), !url.isEmpty {
            out.append("  - \u{6765}\u{6e90}\u{ff1a}\(url)") // 来源：
        }
        if !relatedWords.isEmpty {
            let joined = relatedWords.joined(separator: ", ")
            out.append("  - \u{76f8}\u{5173}\u{8bcd}\u{ff1a}\(joined)") // 相关词：
        }
        out.append("  - id: \(s.id)")
        return out
    }

    private static func renderInterleavedEntries(
        vocab: [VocabClip],
        sentences: [SentenceClip],
        highlightTokenSet: Set<String>,
        includeRelatedWords: Bool,
        relatedWordMap: [String: String]
    ) -> [String] {
        var out: [String] = []
        out.reserveCapacity((vocab.count + sentences.count) * 4)

        var i = 0
        var j = 0
        while i < vocab.count || j < sentences.count {
            if i < vocab.count {
                out.append(contentsOf: renderVocabEntry(vocab[i]))
                i += 1
            }
            if j < sentences.count {
                let related = includeRelatedWords ? relatedWords(in: sentences[j].sentence, tokenToDisplay: relatedWordMap) : []
                out.append(contentsOf: renderSentenceEntry(sentences[j], highlightTokenSet: highlightTokenSet, relatedWords: related))
                j += 1
            }
        }
        return out
    }

    // MARK: - Highlight / Linking

    private struct HighlightTokenMap {
        let tokenToDisplay: [String: String] // token(lowercased) -> display word (first token, original casing)
        let tokenSet: Set<String>            // tokens for O(1) lookup
    }

    private static func makeHighlightTokenMap(existingLines: [String], newVocab: [VocabClip]) -> HighlightTokenMap {
        var map: [String: String] = [:]
        map.reserveCapacity(128)

        func addWord(_ rawWord: String) {
            let raw = rawWord.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
            guard let first = raw.split(whereSeparator: { $0.isWhitespace }).first else { return }
            let cleaned = String(first).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            guard cleaned.count >= 3 else { return }
            // Keep tokens aligned with our boundary regex (ASCII A-Z only) to avoid surprising matches.
            guard cleaned.allSatisfy({ $0.isASCII && $0.isLetter }) else { return }
            let token = cleaned.lowercased()
            if map[token] == nil {
                map[token] = cleaned
            }
        }

        // Existing vocab entries (including Mastered).
        let blocks = splitIntoEntryBlocks(existingLines)
        for b in blocks where b.kind == .vocab {
            guard let firstLine = b.lines.first else { continue }
            guard let head = checklistHeadText(firstLine) else { continue }
            addWord(head)
        }

        // Newly appended vocab (if any).
        for v in newVocab {
            addWord(v.word)
        }

        return HighlightTokenMap(tokenToDisplay: map, tokenSet: Set(map.keys))
    }

    private static func checklistHeadText(_ line: String) -> String? {
        // "- [ ] xxx" or "- [x] xxx"
        guard line.hasPrefix("- [") else { return nil }
        guard let r = line.range(of: "] ") else { return nil }
        let rest = line[r.upperBound...]
        let noTag = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first ?? Substring(rest)
        return String(noTag).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applySentenceHighlightInPlace(lines: inout [String], tokenSet: Set<String>) {
        let headings = ["## Review", "## Sentences", "## Mastered Sentences"]
        for heading in headings {
            guard let h = headingIndex(heading, lines: lines) else { continue }
            let end = endOfSection(startingAt: h, lines: lines)
            if h + 1 >= end { continue }

            let range = (h + 1)..<end
            let sectionLines = Array(lines[range])
            let blocks = splitIntoEntryBlocks(sectionLines)

            var rebuilt: [String] = []
            rebuilt.reserveCapacity(sectionLines.count)

            for b in blocks {
                if b.kind == .sentence, var first = b.lines.first, checklistHeadText(first) != nil {
                    guard let r = first.range(of: "] ") else {
                        rebuilt.append(contentsOf: b.lines)
                        continue
                    }
                    let prefix = String(first[..<r.upperBound])
                    let rest = String(first[r.upperBound...])
                    let updatedRest = boldKeywords(in: rest, tokenSet: tokenSet)
                    first = prefix + updatedRest

                    var newLines = b.lines
                    newLines[0] = first
                    rebuilt.append(contentsOf: newLines)
                } else {
                    rebuilt.append(contentsOf: b.lines)
                }
            }

            lines.replaceSubrange(range, with: rebuilt)
        }
    }

    private static func upsertRelatedWordsInPlace(lines: inout [String], tokenToDisplay: [String: String]) {
        let headings = ["## Review", "## Sentences", "## Mastered Sentences"]
        for heading in headings {
            guard let h = headingIndex(heading, lines: lines) else { continue }
            let end = endOfSection(startingAt: h, lines: lines)
            if h + 1 >= end { continue }

            let range = (h + 1)..<end
            let sectionLines = Array(lines[range])
            let blocks = splitIntoEntryBlocks(sectionLines)

            var rebuilt: [String] = []
            rebuilt.reserveCapacity(sectionLines.count)

            for b in blocks {
                guard b.kind == .sentence, let first = b.lines.first, let head = checklistHeadText(first) else {
                    rebuilt.append(contentsOf: b.lines)
                    continue
                }

                let related = relatedWords(in: head, tokenToDisplay: tokenToDisplay)
                if related.isEmpty {
                    // Remove existing 相关词 line if any.
                    rebuilt.append(contentsOf: b.lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("- 相关词：") })
                    continue
                }

                let joined = related.joined(separator: ", ")
                let relatedLine = "  - \u{76f8}\u{5173}\u{8bcd}\u{ff1a}\(joined)" // 相关词：

                var newLines: [String] = []
                newLines.reserveCapacity(b.lines.count + 1)
                for line in b.lines {
                    // Drop old 相关词 line (if any) so the operation is idempotent.
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("- 相关词：") {
                        continue
                    }
                    newLines.append(line)
                }

                if let idIdx = newLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- id:") && $0.contains("sent_") }) {
                    newLines.insert(relatedLine, at: idIdx)
                } else {
                    newLines.append(relatedLine)
                }
                rebuilt.append(contentsOf: newLines)
            }

            lines.replaceSubrange(range, with: rebuilt)
        }
    }

    private static func relatedWords(in sentence: String, tokenToDisplay: [String: String]) -> [String] {
        let text = sentence.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        if text.isEmpty { return [] }

        var out: [String] = []
        out.reserveCapacity(8)
        var seen: Set<String> = []
        seen.reserveCapacity(8)

        // For "related words", count matches even if the word is already bolded (**word**).
        scanASCIIWords(text) { rawWord, lower in
            guard let display = tokenToDisplay[lower] else { return }
            if !seen.contains(lower) {
                seen.insert(lower)
                out.append(display)
            }
        }

        return out
    }

    private static func boldKeywords(in sentence: String, tokenSet: Set<String>) -> String {
        guard !tokenSet.isEmpty else { return sentence }

        // One-pass highlighter:
        // - only highlights ASCII-letter words
        // - ignores segments already inside **bold**
        let chars = Array(sentence)
        var out = String()
        out.reserveCapacity(chars.count + 16)

        var i = 0
        var inBold = false

        while i < chars.count {
            // Toggle markdown bold markers.
            if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "*" {
                inBold.toggle()
                out.append("**")
                i += 2
                continue
            }

            if !inBold, isASCIILetter(chars[i]) {
                let start = i
                i += 1
                while i < chars.count, isASCIILetter(chars[i]) {
                    i += 1
                }
                let word = String(chars[start..<i])
                let lower = word.lowercased()
                if tokenSet.contains(lower) {
                    out.append("**")
                    out.append(word)
                    out.append("**")
                } else {
                    out.append(word)
                }
                continue
            }

            out.append(chars[i])
            i += 1
        }

        return out
    }

    private static func scanASCIIWordsIgnoringBold(_ text: String, visitor: (String, String) -> Void) {
        let chars = Array(text)
        var i = 0
        var inBold = false

        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "*" {
                inBold.toggle()
                i += 2
                continue
            }

            if !inBold, isASCIILetter(chars[i]) {
                let start = i
                i += 1
                while i < chars.count, isASCIILetter(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                visitor(word, word.lowercased())
                continue
            }

            i += 1
        }
    }

    private static func scanASCIIWords(_ text: String, visitor: (String, String) -> Void) {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if isASCIILetter(chars[i]) {
                let start = i
                i += 1
                while i < chars.count, isASCIILetter(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                visitor(word, word.lowercased())
                continue
            }
            i += 1
        }
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        let v = u.value
        return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }

    // MARK: - Section append helpers

    private static func append(toSection heading: String, entryLines: [String], lines: inout [String]) {
        guard !entryLines.isEmpty else {
            ensureHeadingExists(heading, lines: &lines)
            return
        }

        if let h = headingIndex(heading, lines: lines) {
            // Find end of this section (next "## " heading or EOF).
            var end = h + 1
            while end < lines.count {
                if lines[end].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ") {
                    break
                }
                end += 1
            }

            // Trim trailing blank lines inside the section.
            while end > h + 1, lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                end -= 1
            }

            // Ensure there is a blank line between existing content and appended content.
            if end > h + 1, !lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.insert("", at: end)
                end += 1
            }

            lines.insert(contentsOf: entryLines, at: end)
            lines.insert("", at: end + entryLines.count)
            return
        }

        // Section doesn't exist yet; create it (preferably before any "Mastered" sections).
        ensureHeadingExists(heading, lines: &lines)
        guard let h2 = headingIndex(heading, lines: lines) else { return }

        var end = h2 + 1
        while end < lines.count {
            if lines[end].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ") {
                break
            }
            end += 1
        }
        while end > h2 + 1, lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }

        lines.insert(contentsOf: entryLines, at: end)
        lines.insert("", at: end + entryLines.count)
    }

    private static func headingIndex(_ heading: String, lines: [String]) -> Int? {
        lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading })
    }

    private static func endOfSection(startingAt headingIndex: Int, lines: [String]) -> Int {
        var i = headingIndex + 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ") {
                break
            }
            i += 1
        }
        return i
    }

    // MARK: - ID Extract

    private static let sentRegex = try! NSRegularExpression(pattern: "\\bsent_[0-9a-f]{40}\\b", options: [])
    private static let vocabRegex = try! NSRegularExpression(pattern: "\\bvocab_[0-9a-f]{40}\\b", options: [])

    static func extractIDs(from text: String) -> (sentences: Set<String>, vocab: Set<String>) {
        let ns = text as NSString
        var s: Set<String> = []
        var v: Set<String> = []

        for m in sentRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            s.insert(ns.substring(with: m.range))
        }
        for m in vocabRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            v.insert(ns.substring(with: m.range))
        }
        return (s, v)
    }
}

private extension String {
    func oeiStrippingSurroundingSlashes() -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return t }
        if t.hasPrefix("/") && t.hasSuffix("/") {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    func oeiNormalizeLineEndings() -> String {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
