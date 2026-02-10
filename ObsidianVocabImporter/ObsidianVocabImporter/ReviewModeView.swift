import Foundation
import SwiftUI

enum ReviewHideMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case hideEnglish
    case hideChinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不遮挡"
        case .hideEnglish: return "遮挡英文"
        case .hideChinese: return "遮挡中文"
        }
    }
}

enum ReviewItemKind: Sendable {
    case vocabulary
    case sentence

    var displayName: String {
        switch self {
        case .vocabulary: return "词汇"
        case .sentence: return "句子"
        }
    }
}

struct ReviewItem: Identifiable, Hashable, Sendable {
    let id: String // vocab_xxx / sent_xxx
    let kind: ReviewItemKind
    let isChecked: Bool
    let english: String
    let chinese: String
    let source: String
}

@MainActor
final class ReviewModeViewModel: ObservableObject {
    @Published var date: Date = Date()
    @Published var hideMode: ReviewHideMode = .hideChinese

    @Published var items: [ReviewItem] = []
    @Published var currentIndex: Int = 0
    @Published var revealed: Bool = false

    @Published var statusText: String = ""
    @Published var isWorking: Bool = false

    var vaultURLOverride: URL?

    func resolvedVaultURL() -> URL? {
        vaultURLOverride ?? VaultUtilities.persistedVaultURL()
    }

    var currentItem: ReviewItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    func loadToday() {
        load(for: date)
    }

    func load(for date: Date) {
        guard !isWorking else { return }
        statusText = ""
        revealed = false
        items = []
        currentIndex = 0

        guard let vaultURL = resolvedVaultURL() else {
            statusText = "缺少 Vault：请先在“导入”页选择一次 Obsidian Vault。"
            return
        }

        let prefs = PreferencesSnapshot.load()
        let dateYMD = ymd(from: date)
        let fileURL = VaultUtilities.dailyReviewFileURL(vaultURL: vaultURL, preferences: prefs, dateYMD: dateYMD)

        isWorking = true
        Task.detached(priority: .userInitiated) {
            let text = VaultUtilities.readTextFileLossy(fileURL)
            let parsed: [ReviewItem]
            if let text {
                parsed = Self.parseItems(markdown: text)
            } else {
                parsed = []
            }

            await MainActor.run {
                self.isWorking = false
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    self.statusText = "当天文件不存在：\(VaultUtilities.relativePath(from: vaultURL, to: fileURL))"
                    return
                }
                if text == nil {
                    self.statusText = "无法读取 Markdown（编码未知）：\(VaultUtilities.relativePath(from: vaultURL, to: fileURL))"
                    return
                }
                self.items = parsed
                self.currentIndex = 0
                self.revealed = false
                self.statusText = parsed.isEmpty ? "当天文件内没有可识别条目（或未包含 id）。" : "已加载：\(parsed.count) 条"
            }
        }
    }

    func next() {
        guard !items.isEmpty else { return }
        currentIndex = min(currentIndex + 1, items.count - 1)
        revealed = false
    }

    func previous() {
        guard !items.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        revealed = false
    }

    func showAnswer() {
        revealed = true
    }

    func markWrongOnceAndNext() {
        guard !isWorking else { return }
        guard let item = currentItem else { return }
        guard let vaultURL = resolvedVaultURL() else { return }

        let prefs = PreferencesSnapshot.load()
        let dateYMD = ymd(from: date)

        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let changed = try QuickCaptureEngine.markWrongOnce(id: item.id, dateYMD: dateYMD, vaultURL: vaultURL, preferences: prefs)
                await MainActor.run {
                    self.isWorking = false
                    self.statusText = changed ? "已标记 #wrong：\(item.id)" : "已存在 #wrong 或未找到条目：\(item.id)"
                    self.next()
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.statusText = "标记失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func ymd(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? Calendar.current.component(.year, from: Date())
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return DateParsing.formatYMD(year: year, month: month, day: day)
    }

    nonisolated static func parseItems(markdown: String) -> [ReviewItem] {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")

        // Keep regex local to avoid any global/shared-state concurrency warnings under strict checks.
        let vocabRegex = try! NSRegularExpression(pattern: "\\bvocab_[0-9a-f]{40}\\b", options: [])
        let sentRegex = try! NSRegularExpression(pattern: "\\bsent_[0-9a-f]{40}\\b", options: [])

        enum SectionKind {
            case none
            case activeVocab
            case activeSentences
            case activeReview
            case mastered
        }

        func sectionKind(for heading: String) -> SectionKind {
            switch heading {
            case "## Vocabulary": return .activeVocab
            case "## Sentences": return .activeSentences
            case "## Review": return .activeReview
            case "## Mastered Vocabulary", "## Mastered Sentences": return .mastered
            default: return .none
            }
        }

        func headText(_ line: String) -> String? {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("- [") else { return nil }
            guard let r = t.range(of: "] ") else { return nil }
            let rest = t[r.upperBound...]
            return stripTrailingAppTags(String(rest))
        }

        func stripTrailingAppTags(_ s: String) -> String {
            // Only strip tags that this app writes automatically.
            // Do not split on '#' in general, otherwise words like "C#" would be truncated.
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

        func extractID(from block: String) -> String? {
            // Prefer vocab id if both somehow exist.
            let ns = block as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = vocabRegex.firstMatch(in: block, options: [], range: range) {
                return ns.substring(with: m.range)
            }
            if let m = sentRegex.firstMatch(in: block, options: [], range: range) {
                return ns.substring(with: m.range)
            }
            return nil
        }

        func value(after prefix: String, in blockLines: [String]) -> String {
            func stripTrailingComments(_ s: String) -> String {
                // IDs are stored as inline HTML comments like: <!-- id: sent_xxx -->
                // Keep UI clean by stripping trailing comments.
                if let r = s.range(of: "<!--") {
                    return String(s[..<r.lowerBound]).oeiTrimmed()
                }
                return s
            }
            for raw in blockLines {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(prefix) {
                    return stripTrailingComments(String(t.dropFirst(prefix.count)).oeiTrimmed())
                }
            }
            return ""
        }

        var out: [ReviewItem] = []
        out.reserveCapacity(128)

        var section: SectionKind = .none
        var globalSource: String = ""
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## 来源：") {
                globalSource = String(trimmed.dropFirst("## 来源：".count)).oeiTrimmed()
                i += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                section = sectionKind(for: trimmed)
                i += 1
                continue
            }

            let isIncludedSection = (section == .activeVocab || section == .activeSentences || section == .activeReview || section == .mastered)
            if isIncludedSection, trimmed.hasPrefix("- ["), trimmed.contains("]") {
                let isChecked = trimmed.lowercased().hasPrefix("- [x]")
                let startLine = lines[i]
                var block: [String] = [startLine]
                i += 1
                while i < lines.count {
                    let t2 = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if t2.hasPrefix("- [") || t2.hasPrefix("## ") {
                        break
                    }
                    block.append(lines[i])
                    i += 1
                }

                let blockText = block.joined(separator: "\n")
                guard let id = extractID(from: blockText) else { continue }
                guard let english = headText(startLine), !english.isEmpty else { continue }

                let kind: ReviewItemKind
                if id.hasPrefix("vocab_") {
                    kind = .vocabulary
                } else {
                    kind = .sentence
                }

                let chinese: String
                switch kind {
                case .vocabulary:
                    chinese = value(after: "- 释义：", in: block)
                case .sentence:
                    chinese = value(after: "- 中文：", in: block)
                }

                var source = value(after: "- 来源：", in: block)
                if source.isEmpty {
                    source = globalSource
                }
                out.append(ReviewItem(id: id, kind: kind, isChecked: isChecked, english: english, chinese: chinese, source: source))
                continue
            }

            i += 1
        }

        return out
    }
}

struct ReviewModeView: View {
    @ObservedObject var vm: ReviewModeViewModel

    private func displayEnglish(_ item: ReviewItem) -> String {
        let shouldHide = (vm.hideMode == .hideEnglish && !vm.revealed)
        return shouldHide ? "••••••" : item.english
    }

    private func displayChinese(_ item: ReviewItem) -> String {
        let shouldHide = (vm.hideMode == .hideChinese && !vm.revealed)
        if shouldHide { return "••••••" }
        return item.chinese.isEmpty ? "(无)" : item.chinese
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("今日复习（应用内快速刷）")
                    .font(.headline)

                DatePicker("日期", selection: $vm.date, displayedComponents: .date)
                    .labelsHidden()

                Button("加载") { vm.loadToday() }
                    .disabled(vm.isWorking)

                Picker("遮挡", selection: $vm.hideMode) {
                    ForEach(ReviewHideMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .frame(width: 160)

                Spacer()

                Text(vm.items.isEmpty ? "0/0" : "\(vm.currentIndex + 1)/\(vm.items.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let item = vm.currentItem {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.kind.displayName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(item.isChecked ? "已勾选" : "未勾选")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    Text(displayEnglish(item))
                        .font(.system(size: 22, weight: .semibold, design: .default))

                    HStack(spacing: 8) {
                        Text(item.kind == .sentence ? "中文" : "释义")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(displayChinese(item))
                            .font(.system(.body, design: .default))
                    }

                    if !item.source.isEmpty {
                        HStack(spacing: 8) {
                            Text("来源")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            Text(item.source)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button("上一个") { vm.previous() }
                            .disabled(vm.isWorking || vm.currentIndex <= 0)

                        Button("错（标记 #wrong）") { vm.markWrongOnceAndNext() }
                            .disabled(vm.isWorking)

                        Button("显示答案") { vm.showAnswer() }
                            .disabled(vm.isWorking)
                            .keyboardShortcut(.defaultAction)

                        Button("下一个") { vm.next() }
                            .disabled(vm.isWorking || vm.currentIndex >= vm.items.count - 1)

                        Spacer()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .cornerRadius(12)
            } else {
                Text("暂无可复习条目。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !vm.statusText.isEmpty {
                Text(vm.statusText)
                    .font(.footnote)
                    .foregroundStyle(vm.statusText.contains("失败") ? .red : .secondary)
            }
        }
        .padding(16)
        // Keep the UI usable on smaller screens/windows.
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            // Avoid auto-loading on every tab switch; only load once when empty.
            if vm.items.isEmpty && vm.statusText.isEmpty {
                vm.loadToday()
            }
        }
    }
}
