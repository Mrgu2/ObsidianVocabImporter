import AppKit
import SwiftUI

@MainActor
final class QuickCaptureViewModel: ObservableObject {
    @Published var kind: QuickCaptureKind = .sentence
    @Published var text: String = ""
    @Published var translation: String = ""
    @Published var source: String = ""
    @Published var date: Date = Date()

    @Published var statusText: String = ""
    @Published var isWorking: Bool = false

    // If nil, fall back to persisted vault selection.
    var vaultURLOverride: URL?

    func resolvedVaultURL() -> URL? {
        vaultURLOverride ?? VaultUtilities.persistedVaultURL()
    }

    func resetFromClipboard() {
        let pb = NSPasteboard.general
        let s = pb.string(forType: .string) ?? ""
        let trimmed = s.oeiTrimmed()
        text = trimmed
        translation = ""
        source = ""
        date = Date()
        statusText = ""

        if trimmed.contains(where: { $0.isWhitespace }) {
            kind = .sentence
        } else if trimmed.isEmpty {
            kind = .sentence
        } else {
            kind = .vocabulary
        }
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

            TextField(vm.kind == .sentence ? "中文（可选）" : "释义（可选）", text: $vm.translation)
                .textFieldStyle(.roundedBorder)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 640, minHeight: 420)
    }
}
