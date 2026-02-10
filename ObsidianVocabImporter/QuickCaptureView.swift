import AppKit
import SwiftUI

@MainActor
final class QuickCaptureViewModel: ObservableObject {
    @Published var kind: QuickCaptureKind = .sentence
    @Published var text: String = ""
    @Published var translation: String = ""
    @Published var contextSentence: String = ""
    @Published var source: String = ""
    @Published var date: Date = Date()

    @Published var statusText: String = ""
    @Published var isWorking: Bool = false
    @Published var isLookingUpMeaning: Bool = false
    @Published var meaningLookupHint: String = ""

    // If nil, fall back to persisted vault selection.
    var vaultURLOverride: URL?

    private var lastLookupKey: String = ""
    private var pendingLookupTask: Task<Void, Never>?

    func resolvedVaultURL() -> URL? {
        vaultURLOverride ?? VaultUtilities.persistedVaultURL()
    }

    private func containsHan(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs + Extension A (good enough heuristic for zh meanings).
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    private func looksLikeSentence(_ s: String) -> Bool {
        let t = s.oeiTrimmed()
        if t.count >= 50 { return true }
        let wordCount = t.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount >= 6 { return true }
        // Typical sentence punctuation.
        if t.contains(".") || t.contains("!") || t.contains("?") { return true }
        if t.contains("。") || t.contains("！") || t.contains("？") { return true }
        return false
    }

    private func splitInlineWordAndTranslation(_ s: String) -> (word: String, translation: String)? {
        // Common clipboard formats from dictionaries/flashcard tools.
        // Keep it conservative: only split when there is an obvious delimiter and both sides non-empty.
        let candidates = ["\t", " - ", " – ", " — ", " : ", " ： ", ":", "："]
        for sep in candidates {
            let parts = s.components(separatedBy: sep)
            if parts.count >= 2 {
                let left = parts[0].oeiTrimmed()
                let right = parts.dropFirst().joined(separator: sep).oeiTrimmed()
                if !left.isEmpty && !right.isEmpty {
                    return (left, right)
                }
            }
        }
        return nil
    }

    private func sanitizeLookupTerm(_ raw: String) -> String {
        var s = raw.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
        if s.isEmpty { return s }

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

    func scheduleMeaningLookupDebounced() {
        pendingLookupTask?.cancel()
        pendingLookupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.lookupMeaningFromSystemDictionaryIfNeeded(force: false)
            }
        }
    }

    func lookupMeaningFromSystemDictionaryIfNeeded(force: Bool = false) {
        meaningLookupHint = ""

        guard kind == .vocabulary else { return }
        guard !isWorking, !isLookingUpMeaning else { return }
        if !force, !translation.oeiTrimmed().isEmpty { return }

        let term = sanitizeLookupTerm(text)
        guard !term.isEmpty else { return }
        guard term.count <= 80 else { return }
        guard !containsHan(term) else { return }
        guard !looksLikeSentence(term) else { return }

        let prefs = PreferencesSnapshot.load()
        let lookupMode = prefs.dictionaryLookupMode

        let key = "\(kind.rawValue)|\(term.lowercased())"
        if !force, key == lastLookupKey { return }
        lastLookupKey = key

        isLookingUpMeaning = true

        Task.detached(priority: .userInitiated) {
            let meaning = SystemDictionaryLookup.lookupMeaningSingleLine(term: term, mode: lookupMode)
            await MainActor.run {
                self.isLookingUpMeaning = false
                if let meaning, !meaning.isEmpty {
                    // Only fill when still empty to avoid racing with user input.
                    if self.translation.oeiTrimmed().isEmpty {
                        self.translation = meaning
                    }
                    self.meaningLookupHint = "已从系统词典填充释义"
                } else {
                    self.meaningLookupHint = "系统词典未找到释义（可在 macOS“词典”App 里安装英汉词典）"
                }
            }
        }
    }

    func resetFromClipboard() {
        let pb = NSPasteboard.general
        let s = pb.string(forType: .string) ?? ""
        let trimmed = s.oeiTrimmed()
        // Clipboard capture can come in 2 shapes:
        // 1) Plain word/phrase (single or a few words)
        // 2) Two-line format: first line is the selected word/phrase, second line is the full sentence
        //    (useful when watching YouTube and wanting to save both in one shot).
        if trimmed.contains("\n") {
            let lines = trimmed
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.oeiTrimmed() }
                .filter { !$0.isEmpty }
            if lines.count == 2 {
                // Ambiguous: could be (word, meaning) or (word, sentence).
                // Heuristic: if the 2nd line contains Chinese and doesn't look like a sentence, treat it as meaning.
                let l1 = lines[0]
                let l2 = lines[1]
                text = l1
                if containsHan(l2) && !looksLikeSentence(l2) && !containsHan(l1) {
                    translation = l2.oeiCompressWhitespaceToSingleSpaces()
                    contextSentence = ""
                } else {
                    translation = ""
                    contextSentence = l2.oeiCompressWhitespaceToSingleSpaces()
                }
                kind = .vocabulary
            } else if lines.count >= 3 {
                // Prefer: first line = word, remaining = context sentence (joined).
                // If the remaining lines are mostly Chinese and short, treat them as meaning.
                let l1 = lines[0]
                let rest = Array(lines.dropFirst())
                text = l1
                let restJoined = rest.joined(separator: " ").oeiCompressWhitespaceToSingleSpaces()
                if containsHan(restJoined) && !looksLikeSentence(restJoined) && restJoined.count <= 80 && !containsHan(l1) {
                    translation = restJoined
                    contextSentence = ""
                } else {
                    translation = ""
                    contextSentence = restJoined
                }
                kind = .vocabulary
            } else {
                text = trimmed
                translation = ""
                contextSentence = ""
            }
        } else if let split = splitInlineWordAndTranslation(trimmed), containsHan(split.translation) {
            text = split.word
            translation = split.translation
            contextSentence = ""
            kind = .vocabulary
        } else {
            text = trimmed
            translation = ""
            contextSentence = ""
        }
        source = ""
        date = Date()
        statusText = ""
        meaningLookupHint = ""

        // If the clipboard didn't indicate a specific format, infer kind.
        if kind != .vocabulary {
            let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
            if trimmed.isEmpty {
                kind = .sentence
            } else if wordCount <= 4 {
                // Treat short multi-word selections as phrases.
                kind = .vocabulary
            } else {
                kind = .sentence
            }
        }

        // Best-effort: if user only captured a word/phrase and didn't provide meaning, try system dictionary.
        lookupMeaningFromSystemDictionaryIfNeeded(force: false)
    }

    func performCapture(onFinish: ((Result<QuickCaptureResult, Error>) -> Void)? = nil) {
        guard !isWorking else { return }

        statusText = ""
        guard let vaultURL = resolvedVaultURL() else {
            statusText = "缺少 Vault：请先在“导入”页选择一次 Obsidian Vault。"
            return
        }

        let prefs = PreferencesSnapshot.load()
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? Calendar.current.component(.year, from: Date())
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let dateYMD = DateParsing.formatYMD(year: year, month: month, day: day)

        let input = QuickCaptureInput(
            kind: kind,
            text: text,
            translation: translation,
            source: source,
            contextSentence: contextSentence,
            dateYMD: dateYMD
        )

        isWorking = true

        Task.detached(priority: .userInitiated) {
            do {
                let result = try QuickCaptureEngine.capture(input: input, vaultURL: vaultURL, preferences: prefs)
                await MainActor.run {
                    self.statusText = result.message
                    self.isWorking = false
                    onFinish?(.success(result))
                }
            } catch {
                await MainActor.run {
                    self.statusText = "写入失败：\(error.localizedDescription)"
                    self.isWorking = false
                    onFinish?(.failure(error))
                }
            }
        }
    }
}

struct QuickCaptureView: View {
    @ObservedObject var vm: QuickCaptureViewModel
    let onClose: (() -> Void)?

    @AppStorage(PreferencesKeys.dictionaryLookupMode) private var dictionaryLookupModeRaw: String = Defaults.dictionaryLookupMode.rawValue

    private var dictionaryLookupModeBinding: Binding<DictionaryLookupMode> {
        Binding(
            get: { DictionaryLookupMode(rawValue: dictionaryLookupModeRaw) ?? Defaults.dictionaryLookupMode },
            set: { dictionaryLookupModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("快速捕获")
                    .font(.headline)
                Button("从剪贴板填充") { vm.resetFromClipboard() }
                    .disabled(vm.isWorking)
                Spacer()
                Text("全局快捷键：Control + Option + Command + V")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Picker("类型", selection: $vm.kind) {
                    ForEach(QuickCaptureKind.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: vm.kind) { _ in
                    vm.lookupMeaningFromSystemDictionaryIfNeeded(force: false)
                }

                DatePicker("日期", selection: $vm.date, displayedComponents: .date)
                    .labelsHidden()

                Spacer()
            }

            TextEditor(text: $vm.text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .onChange(of: vm.text) { _ in
                    vm.scheduleMeaningLookupDebounced()
                }

            HStack(spacing: 8) {
                TextField(vm.kind == .sentence ? "中文（可选）" : "释义（可选）", text: $vm.translation)
                    .textFieldStyle(.roundedBorder)

                if vm.kind == .vocabulary {
                    Picker("词典", selection: dictionaryLookupModeBinding) {
                        ForEach(DictionaryLookupMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: dictionaryLookupModeRaw) { _ in
                        // Try again under the new mode when translation is empty.
                        vm.lookupMeaningFromSystemDictionaryIfNeeded(force: false)
                    }

                    Button("查词") { vm.lookupMeaningFromSystemDictionaryIfNeeded(force: true) }
                        .disabled(vm.isWorking || vm.isLookingUpMeaning || vm.text.oeiTrimmed().isEmpty)
                    if vm.isLookingUpMeaning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if vm.kind == .vocabulary, !vm.meaningLookupHint.isEmpty {
                Text(vm.meaningLookupHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if vm.kind == .vocabulary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("完整句子（可选）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $vm.contextSentence)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 64, maxHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                }
            }

            TextField("来源（可选：URL/字幕文件名/时间戳）", text: $vm.source)
                .textFieldStyle(.roundedBorder)

            if !vm.statusText.isEmpty {
                Text(vm.statusText)
                    .font(.footnote)
                    .foregroundStyle(vm.statusText.hasPrefix("写入失败") ? .red : .secondary)
            }

            HStack {
                Button("取消") { onClose?() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("写入") {
                    vm.performCapture { r in
                        if case .success(let result) = r, result.outcome == .added {
                            onClose?()
                        }
                    }
                }
                .disabled(vm.isWorking || vm.text.oeiTrimmed().isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }
}
