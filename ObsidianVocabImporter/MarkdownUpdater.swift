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
        preferences: PreferencesSnapshot,
        frontmatterSource: String = "imported"
    ) -> MarkdownUpdateResult {
        let normalizedExisting = existing?.oeiNormalizeLineEndings()
        let (existingSentIDs, existingVocabIDs) = extractIDs(from: normalizedExisting ?? "")

        let filteredSentences = newSentences.filter { !existingSentIDs.contains($0.id) }
        let filteredVocab = newVocab.filter { !existingVocabIDs.contains($0.id) }

        var lines: [String] = normalizedExisting?.components(separatedBy: "\n") ?? []

        // 1) Frontmatter: preserve unknown keys but ensure our required keys exist.
        lines = upsertFrontmatter(lines: lines, date: date, source: frontmatterSource)

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

        // 6) Formatting normalization:
        // - Hide internal IDs from the rendered note while keeping them in-file for dedup/self-heal.
        // - For quick-captured notes, de-duplicate a single repeated source (e.g. a YouTube URL) by
        //   promoting it to one top-level heading.
        normalizeVocabTranslationPresentationInPlace(lines: &lines)
        normalizeIDLinesInPlace(lines: &lines)
        normalizeCapturedSourcePresentationInPlace(lines: &lines)

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

        // Keep files tidy when the user runs maintenance:
        // - Hide IDs (keep them for dedup/self-heal but avoid visual noise).
        // - If everything in a note shares one source, promote it to a single heading.
        normalizeIDLinesInPlace(lines: &lines)
        normalizeCapturedSourcePresentationInPlace(lines: &lines)

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
        upsertFrontmatter(lines: lines, date: date, source: "imported")
    }

    private static func upsertFrontmatter(lines: [String], date: String, source: String) -> [String] {
        guard !lines.isEmpty else {
            return canonicalFrontmatterLines(date: date, source: source)
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
            let updatedBody = upsertFrontmatterBody(fmBody, date: date, source: source)
            return ["---"] + updatedBody + ["---", ""] + rest
        }

        // No frontmatter detected.
        return canonicalFrontmatterLines(date: date, source: source) + lines
    }

    private static func canonicalFrontmatterLines(date: String, source: String) -> [String] {
        [
            "---",
            "date: \(date)",
            "source: \(source)",
            "tags: [english, review]",
            "---",
            ""
        ]
    }

    private static func upsertFrontmatterBody(_ body: [String], date: String, source: String) -> [String] {
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
                // Preserve existing source to avoid destructively rewriting semantics.
                out.append(line)
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
        if !seenSource { out.append("source: \(source)") }
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

    private static func normalizeIDLinesInPlace(lines: inout [String]) {
        // Keep IDs in-file for dedup/self-heal, but hide them from Obsidian live preview and from our Review UI.
        // We do this by storing IDs in Obsidian comments:
        //   %% id: vocab_xxx %%
        //
        // This function also migrates legacy formats:
        // - "- id: vocab_xxx"
        // - "<!-- id: vocab_xxx -->" (standalone or inline)
        //
        // Target normalized format inside each entry block:
        //   - [ ] head line %% id: vocab_xxx %%
        //     - 释义：...

        func stripIDCommentsFromLine(_ s: String) -> String {
            var t = s
            // Remove inline HTML id comments.
            if let r0 = t.range(of: "<!-- id:") {
                if let r1 = t.range(of: "-->", range: r0.lowerBound..<t.endIndex) {
                    t.removeSubrange(r0.lowerBound..<r1.upperBound)
                } else {
                    t = String(t[..<r0.lowerBound])
                }
            }
            // Remove inline Obsidian id comments.
            if let r0 = t.range(of: "%%") {
                // Best-effort: drop from first %% to next %%.
                if let r1 = t.range(of: "%%", range: r0.upperBound..<t.endIndex) {
                    t.removeSubrange(r0.lowerBound..<r1.upperBound)
                } else {
                    t = String(t[..<r0.lowerBound])
                }
            }
            // Also remove legacy "- id: ..." fragments if user pasted into same line.
            if let r = t.range(of: "- id:") {
                t = String(t[..<r.lowerBound])
            }
            // Trim trailing whitespace created by removals.
            while t.last == " " || t.last == "\t" { t.removeLast() }
            return t
        }

        func extractFirstID(from blockText: String) -> String? {
            let ns = blockText as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = vocabRegex.firstMatch(in: blockText, options: [], range: range) {
                return ns.substring(with: m.range)
            }
            if let m = sentRegex.firstMatch(in: blockText, options: [], range: range) {
                return ns.substring(with: m.range)
            }
            return nil
        }

        func isEntryHeadLine(_ raw: String) -> Bool {
            raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("- [")
        }

        func isHeadingLine(_ raw: String) -> Bool {
            raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ")
        }

        func isLegacyIDOnlyLine(_ raw: String) -> Bool {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("- id:") { return true }
            if t.hasPrefix("<!-- id:") && t.hasSuffix("-->") { return true }
            if t.hasPrefix("%%"), t.contains("id:"), t.hasSuffix("%%") { return true }
            return false
        }

        var i = 0
        while i < lines.count {
            if !isEntryHeadLine(lines[i]) {
                i += 1
                continue
            }

            let headIdx = i
            var end = headIdx + 1
            while end < lines.count {
                if isEntryHeadLine(lines[end]) || isHeadingLine(lines[end]) { break }
                end += 1
            }

            let block = Array(lines[headIdx..<end])
            let blockText = block.joined(separator: "\n")
            guard let id = extractFirstID(from: blockText) else {
                i = end
                continue
            }

            let desiredIDSuffix = " %% id: \(id) %%"

            var rebuilt: [String] = []
            rebuilt.reserveCapacity(block.count)

            // 1) Head line: remove any inline id comments.
            let headClean = stripIDCommentsFromLine(lines[headIdx])
            rebuilt.append(headClean + desiredIDSuffix)

            // 2) Keep the rest of the block, but drop any legacy id-only lines and strip inline id comments.
            if headIdx + 1 < end {
                for raw in lines[(headIdx + 1)..<end] {
                    if isLegacyIDOnlyLine(raw) { continue }
                    let cleaned = stripIDCommentsFromLine(raw)
                    if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Preserve blank lines only if they existed as real separators. Inside blocks,
                        // blank lines tend to make markdown lists harder to read; drop them.
                        continue
                    }
                    rebuilt.append(cleaned)
                }
            }

            lines.replaceSubrange(headIdx..<end, with: rebuilt)
            i = headIdx + rebuilt.count
        }
    }

    private static func normalizeCapturedSourcePresentationInPlace(lines: inout [String]) {
        // For YouTube watching, users commonly capture many clips from the same video URL.
        // Repeating "来源：<url>" for every entry is noisy, so we promote a single repeated source
        // to a top-level heading and remove per-entry source lines.
        var perEntrySources: Set<String> = []
        perEntrySources.reserveCapacity(4)

        func isIndentedSourceLine(_ raw: String) -> Bool {
            raw.hasPrefix("  - 来源：") || raw.hasPrefix("\t- 来源：")
        }

        for raw in lines {
            guard isIndentedSourceLine(raw) else { continue }
            let t = raw.trimmingCharacters(in: .whitespaces)
            let v = String(t.dropFirst("- 来源：".count)).oeiTrimmed()
            if !v.isEmpty {
                perEntrySources.insert(v)
            }
        }

        // Detect existing promoted heading (if any). Important: if a note was previously promoted to a
        // single heading and later gets entries from another source, we must "demote" the heading back
        // into per-entry source lines to avoid losing the original source information.
        let sourceHeadingIndices = lines.enumerated().compactMap { idx, raw -> Int? in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.hasPrefix("## 来源：") || t.hasPrefix("### 来源：")) ? idx : nil
        }
        let sourceHeadingValue: String? = {
            guard sourceHeadingIndices.count == 1 else { return nil }
            let raw = lines[sourceHeadingIndices[0]].trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("## 来源：") {
                return String(raw.dropFirst("## 来源：".count)).oeiTrimmed()
            }
            if raw.hasPrefix("### 来源：") {
                return String(raw.dropFirst("### 来源：".count)).oeiTrimmed()
            }
            return nil
        }()

        if let heading = sourceHeadingValue, !heading.isEmpty {
            // If the file already has a promoted heading and we now see a different per-entry source,
            // it means the day contains multiple sources. Demote the heading back into per-entry lines
            // for entries that don't have an explicit source line.
            if !perEntrySources.isEmpty && (perEntrySources.count != 1 || perEntrySources.first != heading) {
                demoteSingleSourceHeadingInPlace(lines: &lines, source: heading)
                return
            }
        }

        // Only safe to promote when there is exactly one distinct source and the note is not mixed-source.
        guard perEntrySources.count == 1, let only = perEntrySources.first else { return }

        // Remove existing source headings (if any) to keep it stable.
        lines.removeAll(where: {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("## 来源：") || t.hasPrefix("### 来源：")
        })

        // Insert "## 来源：..." after the overview line (and its spacing).
        if let overviewIdx = lines.firstIndex(where: { $0.hasPrefix("**Overview:**") }) {
            var insertAt = overviewIdx + 1
            while insertAt < lines.count, lines[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertAt += 1
            }
            // Keep one blank line separation from surrounding content.
            if insertAt > 0, !lines[insertAt - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.insert("", at: insertAt)
                insertAt += 1
            }
            lines.insert("## 来源：\(only)", at: insertAt)
            lines.insert("", at: insertAt + 1)
        }

        // Remove per-entry source lines (only the indented ones written by this app).
        lines.removeAll(where: { isIndentedSourceLine($0) })
    }

    private static func normalizeVocabTranslationPresentationInPlace(lines: inout [String]) {
        // Reflow long one-line dictionary outputs into multi-line lists for readability.
        // Only touches lines that start with our "  - 释义：" prefix.

        func extractIDComment(from s: String) -> (content: String, idComment: String?) {
            guard let r = s.range(of: "<!-- id:") else { return (s, nil) }
            let left = String(s[..<r.lowerBound]).oeiTrimmed()
            let right = String(s[r.lowerBound...]).oeiTrimmed()
            return (left, right.isEmpty ? nil : right)
        }

        // Same heuristic as SystemDictionaryLookup: only strip pinyin tokens when we see tone marks.
        let marks = "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛÜ"
        let pinyinMarks = CharacterSet(charactersIn: marks)
        let tokenRe = try? NSRegularExpression(
            pattern: #"\b[\p{Script=Latin}\p{M}'’\-]*["# + marks + #"][\p{Script=Latin}\p{M}'’\-]*\b[;,.!?]?"#,
            options: []
        )
        func stripPinyinIfDetected(_ s: String) -> String {
            guard s.rangeOfCharacter(from: pinyinMarks) != nil else { return s }
            guard let tokenRe else { return s }
            let ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = tokenRe.matches(in: s, options: [], range: full)
            if matches.isEmpty { return s }
            var out = s
            for m in matches.reversed() {
                if let r = Range(m.range, in: out) {
                    out.removeSubrange(r)
                }
            }
            return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            guard raw.hasPrefix("  - 释义：") || raw.hasPrefix("\t- 释义：") else {
                i += 1
                continue
            }

            // Already normalized form: "  - 释义： <!-- id: ... -->"
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- 释义： <!-- id:") {
                i += 1
                continue
            }

            let indent = raw.prefix { $0 == " " || $0 == "\t" }
            let afterPrefix: String
            if raw.hasPrefix("  - 释义：") {
                afterPrefix = String(raw.dropFirst("  - 释义：".count))
            } else {
                afterPrefix = String(raw.dropFirst("\t- 释义：".count))
            }

            var (content, idComment) = extractIDComment(from: afterPrefix)
            content = stripPinyinIfDetected(content)
            let formatted = formatVocabTranslationForMarkdownList(content)

            if formatted.count <= 1 {
                let c = (formatted.first ?? content).oeiTrimmed()
                let idSuffix = idComment.map { " \($0)" } ?? ""
                lines[i] = "\(indent)- 释义：\(c)\(idSuffix)"
                i += 1
                continue
            }

            let nestedIndent: String
            if indent.contains("\t") {
                nestedIndent = String(indent) + "\t"
            } else {
                nestedIndent = String(indent) + "  "
            }

            let idSuffix = idComment.map { " \($0)" } ?? ""
            lines[i] = "\(indent)- 释义：\(idSuffix)"

            let nested = formatted.map { "\(nestedIndent)- \($0)" }
            lines.insert(contentsOf: nested, at: i + 1)
            i += 1 + nested.count
        }
    }

    private static func demoteSingleSourceHeadingInPlace(lines: inout [String], source: String) {
        // Remove existing source heading(s) and restore per-entry sources where missing.
        // This is intentionally conservative: if the day mixes multiple sources, we keep per-entry lines
        // to avoid losing information.
        let headingTrimmed = source.oeiTrimmed()
        if headingTrimmed.isEmpty { return }

        // 1) Remove heading lines ("## 来源：..." / "### 来源：...") and any immediate blank line after them.
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("## 来源：") || t.hasPrefix("### 来源：") {
                lines.remove(at: i)
                if i < lines.count, lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.remove(at: i)
                }
                continue
            }
            i += 1
        }

        // 2) For each entry block, if it lacks an indented source line, append one.
        func isEntryHead(_ raw: String) -> Bool {
            raw.trimmingCharacters(in: .whitespaces).hasPrefix("- [")
        }
        func isIndentedSourceLine(_ raw: String) -> Bool {
            raw.hasPrefix("  - 来源：") || raw.hasPrefix("\t- 来源：")
        }

        var idx = 0
        while idx < lines.count {
            if !isEntryHead(lines[idx]) {
                idx += 1
                continue
            }

            var end = idx + 1
            while end < lines.count {
                let t = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("- [") || t.hasPrefix("## ") {
                    break
                }
                end += 1
            }

            var hasSource = false
            if idx < end {
                for k in (idx + 1)..<end where isIndentedSourceLine(lines[k]) {
                    hasSource = true
                    break
                }
            }

            if !hasSource {
                lines.insert("  - 来源：\(headingTrimmed)", at: end)
                end += 1
            }

            idx = end
        }
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

    private static func formatVocabTranslationForMarkdownList(_ raw: String) -> [String] {
        let t = raw.oeiTrimmed()
        if t.isEmpty { return [] }

        let hasHan: Bool = t.unicodeScalars.contains(where: { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        })

        // Break on common dictionary sense markers to improve readability.
        let markers = Set("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")
        let bullets: Set<Character> = ["•"]

        var out: String = ""
        out.reserveCapacity(min(4096, t.count + 32))

        var prevWasNewline = true
        for ch in t {
            // When the definition is long, semicolons are often good split points (examples/usages).
            // Only do this when the text includes Chinese so we don't over-split pure English strings.
            if hasHan, (ch == "；" || ch == ";"), !prevWasNewline {
                out.append(ch)
                out.append("\n")
                prevWasNewline = true
                continue
            }
            if (markers.contains(ch) || bullets.contains(ch)) && !prevWasNewline {
                out.append("\n")
            }
            out.append(ch)
            prevWasNewline = (ch == "\n")
        }

        // Normalize whitespace within each line but preserve line boundaries.
        let lines = out
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).oeiTrimmed() }
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }

        return lines
    }

    private static func renderVocabEntry(_ v: VocabClip) -> [String] {
        let word = v.word.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        let translationRaw = v.translation.oeiTrimmed()
        let source = v.source?.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces() ?? ""

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

        // Keep IDs in-file for dedup/self-heal, but hide them from Obsidian live preview and from our Review UI.
        var out: [String] = ["\(head) %% id: \(v.id) %%"]

        let translationLines = formatVocabTranslationForMarkdownList(translationRaw)
        if translationLines.count <= 1 {
            let translation = (translationLines.first ?? "").oeiTrimmed()
            out.append("  - \u{91ca}\u{4e49}\u{ff1a}\(translation)") // 释义：
        } else {
            out.append("  - \u{91ca}\u{4e49}\u{ff1a}") // 释义：
            out.append(contentsOf: translationLines.map { "    - \($0)" })
        }
        if !source.isEmpty {
            out.insert("  - \u{6765}\u{6e90}\u{ff1a}\(source)", at: out.count) // 来源：
        }
        return out
    }

    private static func renderSentenceEntry(_ s: SentenceClip, highlightTokenSet: Set<String>, relatedWords: [String]) -> [String] {
        let rawSentence = s.sentence.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        let sentence = highlightTokenSet.isEmpty ? rawSentence : boldKeywords(in: rawSentence, tokenSet: highlightTokenSet)
        let translation = s.translation.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()

        var out: [String] = []
        out.reserveCapacity(6)
        out.append("- [ ] \(sentence) %% id: \(s.id) %%")
        out.append("  - \u{4e2d}\u{6587}\u{ff1a}\(translation)") // 中文：
        if let url = s.url?.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces(), !url.isEmpty {
            out.append("  - \u{6765}\u{6e90}\u{ff1a}\(url)") // 来源：
        }
        if !relatedWords.isEmpty {
            let joined = relatedWords.joined(separator: ", ")
            out.append("  - \u{76f8}\u{5173}\u{8bcd}\u{ff1a}\(joined)") // 相关词：
        }
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
        return stripTrailingAppTags(String(rest))
    }

    private static func stripTrailingAppTags(_ s: String) -> String {
        // Only strip tags that this app writes automatically.
        // Do not split on '#' in general, otherwise words like "C#" would be truncated.
        func stripInlineAppComments(_ s: String) -> String {
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

        var t = stripInlineAppComments(s).oeiTrimmed()
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
