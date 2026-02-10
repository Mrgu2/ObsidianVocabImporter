import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SubtitleImportViewModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var cues: [SubtitleCue] = []
    @Published var selectedCueID: UUID?

    @Published var query: String = ""
    @Published var includeSource: Bool = true
    @Published var date: Date = Date()

    @Published var statusText: String = ""
    @Published var isWorking: Bool = false

    var vaultURLOverride: URL?

    func resolvedVaultURL() -> URL? {
        vaultURLOverride ?? VaultUtilities.persistedVaultURL()
    }

    var filteredCues: [SubtitleCue] {
        let q = query.oeiTrimmed().lowercased()
        guard !q.isEmpty else { return cues }
        return cues.filter { cue in
            cue.text.lowercased().contains(q) || cue.start.lowercased().contains(q) || cue.end.lowercased().contains(q)
        }
    }

    func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        var types: [UTType] = []
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
        panel.allowedContentTypes = types.isEmpty ? [UTType.plainText] : types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSubtitleFile(url)
    }

    func loadSubtitleFile(_ url: URL) {
        fileURL = url
        cues = []
        selectedCueID = nil
        statusText = ""

        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let parsed = try SubtitleParser.parse(url: url)
                await MainActor.run {
                    self.cues = parsed
                    self.selectedCueID = parsed.first?.id
                    self.statusText = "已解析：\(parsed.count) 条字幕"
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.statusText = "解析失败：\(error.localizedDescription)"
                    self.isWorking = false
                }
            }
        }
    }

    func importSelectedCue() {
        guard !isWorking else { return }
        guard let vaultURL = resolvedVaultURL() else {
            statusText = "缺少 Vault：请先在“导入”页选择一次 Obsidian Vault。"
            return
        }
        guard let fileURL else {
            statusText = "请先选择字幕文件。"
            return
        }
        guard let selectedCueID, let cue = cues.first(where: { $0.id == selectedCueID }) else {
            statusText = "请先选中一条字幕。"
            return
        }

        let prefs = PreferencesSnapshot.load()
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? Calendar.current.component(.year, from: Date())
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let dateYMD = DateParsing.formatYMD(year: year, month: month, day: day)

        let source: String
        if includeSource {
            let time = cue.timeRangeDisplay
            source = time.isEmpty ? fileURL.lastPathComponent : "\(fileURL.lastPathComponent) @ \(time)"
        } else {
            source = ""
        }

        let input = QuickCaptureInput(kind: .sentence, text: cue.text, translation: "", source: source, contextSentence: "", dateYMD: dateYMD)

        isWorking = true
        statusText = "正在写入…"

        Task.detached(priority: .userInitiated) {
            do {
                let result = try QuickCaptureEngine.capture(input: input, vaultURL: vaultURL, preferences: prefs)
                await MainActor.run {
                    self.statusText = result.message
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.statusText = "写入失败：\(error.localizedDescription)"
                    self.isWorking = false
                }
            }
        }
    }
}

struct SubtitleImportView: View {
    @ObservedObject var vm: SubtitleImportViewModel

    private var selectedCue: SubtitleCue? {
        guard let id = vm.selectedCueID else { return nil }
        return vm.cues.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("字幕文件导入（SRT / VTT）")
                    .font(.headline)
                Spacer()
                Button("选择字幕文件…") { vm.chooseSubtitleFile() }
                    .disabled(vm.isWorking)
            }

            if let url = vm.fileURL {
                Text(url.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("提示：选择一个 .srt 或 .vtt 文件，然后在下方列表中选中一条字幕写入当天 Review。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                DatePicker("日期", selection: $vm.date, displayedComponents: .date)
                Toggle("写入来源（文件名 + 时间戳）", isOn: $vm.includeSource)
                Spacer()
                Button("写入选中字幕") { vm.importSelectedCue() }
                    .disabled(vm.isWorking || vm.selectedCueID == nil)
            }

            TextField("搜索（可选）", text: $vm.query)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                List(selection: $vm.selectedCueID) {
                    ForEach(vm.filteredCues) { cue in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(cue.timeRangeDisplay)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                            Text(cue.text)
                                .lineLimit(2)
                        }
                        .tag(cue.id)
                    }
                }
                .frame(minWidth: 260, minHeight: 240)

                VStack(alignment: .leading, spacing: 8) {
                    Text("预览")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let cue = selectedCue {
                        Text(cue.timeRangeDisplay)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(cue.text)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.vertical, 4)
                        }
                    } else {
                        Text("未选择")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .frame(minWidth: 220)
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
    }
}
