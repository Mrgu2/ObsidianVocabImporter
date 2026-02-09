import SwiftUI
import UniformTypeIdentifiers

struct ImportTabView: View {
    @ObservedObject var vm: ImporterViewModel
    @State private var isDropTargeted = false

    private func columnMappingSheet(pending: PendingColumnMapping) -> some View {
        ColumnMappingView(
            pending: pending,
            onCancel: {
                vm.pendingColumnMapping = nil
            },
            onConfirm: { mapping in
                vm.applyColumnMapping(mapping)
                vm.pendingColumnMapping = nil
                vm.preparePreview()
            }
        )
    }

    var body: some View { rootView }

    private var rootView: some View {
        VStack(alignment: .leading, spacing: 12) {
            vaultSection
            modeSection
            csvFilesSection
            previewSection
            importActionsRow
            maintenanceSection
            momoSection
            resultSection
        }
        .padding(14)
        .frame(minWidth: 860, minHeight: 720)
        .sheet(item: $vm.pendingColumnMapping, content: columnMappingSheet)
        .onChange(of: vm.vaultURL) { _, _ in vm.schedulePreviewRefresh() }
        .onChange(of: vm.sentenceCSVURL) { _, _ in vm.schedulePreviewRefresh() }
        .onChange(of: vm.vocabCSVURL) { _, _ in vm.schedulePreviewRefresh() }
        .onChange(of: vm.mode) { _, _ in vm.schedulePreviewRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Preferences affect output path and year completion; invalidate preview when they change.
            vm.schedulePreviewRefresh()
        }
    }

    private var vaultSection: some View {
        GroupBox("Obsidian Vault") {
            HStack(spacing: 8) {
                Button("选择文件夹…") { vm.chooseVaultFolder() }
                    .disabled(vm.isWorking)

                Text(vm.vaultURL?.path ?? "(未选择)")
                    .font(.footnote)
                    .foregroundStyle(vm.vaultURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var modeSection: some View {
        GroupBox("导入模式") {
            Picker("", selection: $vm.mode) {
                ForEach(ImportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isWorking)
        }
    }

    private var csvFilesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("选择句子 CSV…") { vm.chooseSentenceCSV() }
                        .disabled(vm.isWorking)
                    Text(vm.sentenceCSVURL?.path ?? "(未选择)")
                        .font(.footnote)
                        .foregroundStyle(vm.sentenceCSVURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button("选择词汇 CSV…") { vm.chooseVocabularyCSV() }
                        .disabled(vm.isWorking)
                    Text(vm.vocabCSVURL?.path ?? "(未选择)")
                        .font(.footnote)
                        .foregroundStyle(vm.vocabCSVURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Text("提示：你可以把 CSV 拖拽到窗口中，应用会通过表头自动识别“句子 CSV / 词汇 CSV”并填充。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(2)
        } label: {
            HStack(spacing: 8) {
                Text("CSV 文件")
                if isDropTargeted {
                    Text("（松开以填充）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !vm.isWorking else { return false }
            vm.handleDrop(providers: providers)
            return true
        }
    }

    private var previewSection: some View {
        GroupBox("导入预览") {
            VStack(alignment: .leading, spacing: 10) {
                if let pending = vm.pendingColumnMapping {
                    Text("需要列映射：\(pending.kind.displayName) CSV（请在弹窗中选择列）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let hint = vm.missingInputHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if vm.isWorking {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: vm.progress)
                        Text(vm.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = vm.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let prepared = vm.preparedPlan {
                    preparedPlanView(prepared)
                } else {
                    Text("暂无预览。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func preparedPlanView(_ prepared: PreparedImportPlan) -> some View {
        if !prepared.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("预警（存在“错误”时将禁用导入）：")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(prepared.warnings) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        let pathText = w.relatedPath.map { "  (\($0))" } ?? ""
                        Text("[\(severityLabel(w.severity))] \(w.title)\(pathText)")
                            .font(.footnote)
                            .foregroundStyle(severityColor(w.severity))
                        if let detail = w.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if prepared.hasBlockingWarnings {
                    Text("存在错误预警：为避免写乱笔记，已禁用导入。你仍然可以只做预览与检查。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(.thinMaterial)
            .cornerRadius(8)
        }

        HStack(spacing: 16) {
            Text("日期分组：\(prepared.days.count)")
            Text("新增：\(prepared.totalNewItems)（词汇 \(prepared.totalNewVocab) / 句子 \(prepared.totalNewSentences)）")
            Text("跳过重复：\(prepared.skippedDuplicatesTotal)（索引 \(prepared.skippedIndexDuplicates) / 批次 \(prepared.skippedBatchDuplicates) / 文件 \(prepared.skippedFileDuplicates)）")
            Text("解析失败：\(prepared.parseFailuresCount)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(prepared.days) { day in
                    DisclosureGroup("\(day.date)  (+V \(day.appendedVocabIDs.count) / +S \(day.appendedSentenceIDs.count))  →  \(day.relativeOutputPath)") {
                        TextEditor(text: .constant(day.markdownPreview))
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 220)
                            .disabled(true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 320)
    }

    private var importActionsRow: some View {
        HStack(spacing: 10) {
            Button("刷新预览") { vm.preparePreview() }
                .disabled(vm.isWorking)

            Button("导入") { vm.performImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canImport || vm.isWorking)

            Spacer()
        }
    }

    private var maintenanceSection: some View {
        GroupBox("维护（扫描/归档已掌握）") {
            VStack(alignment: .leading, spacing: 10) {
                Text("当你在 Obsidian 里把条目前的 [ ] 勾选为 [x] 后，可以用扫描功能把已掌握条目自动移动到 Mastered 分区（保持文件可读性）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("扫描预览（不写入）") { vm.scanAndArchiveMastered(previewOnly: true) }
                        .disabled(vm.vaultURL == nil || vm.isWorking)

                    Button("执行归档（写入）") { vm.scanAndArchiveMastered(previewOnly: false) }
                        .disabled(vm.vaultURL == nil || vm.isWorking)

                    Spacer()
                }
            }
        }
    }

    private var momoSection: some View {
        GroupBox("墨墨单词本导出（纯单词）") {
            VStack(alignment: .leading, spacing: 10) {
                Text("从词汇 CSV 导出“纯单词（一行一个）”，适合直接粘贴到墨墨单词本的“词本正文”。导出会去重：同一单词多次导出只会输出一次。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if vm.vocabCSVURL == nil {
                    Text("提示：请先选择词汇 CSV。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("生成导出预览") { vm.prepareMomoExportPreview() }
                        .disabled(!vm.canMomoExport || vm.isWorking)

                    Button("复制新增单词") { vm.copyMomoWordsToClipboard() }
                        .disabled(!vm.canMomoExport || vm.isWorking)

                    Button("导出到 TXT…") { vm.exportMomoWordsToTXT() }
                        .disabled(!vm.canMomoExport || vm.isWorking)

                    Button("打开导出索引") { vm.openMomoExportIndexFile() }
                        .disabled(vm.vaultURL == nil)

                    Spacer()
                }

                if let p = vm.momoPreview {
                    HStack(spacing: 16) {
                        Text("新增单词：\(p.wordCount)")
                        Text("跳过重复：\(p.skippedTotal)（索引 \(p.skippedIndexDuplicates) / 批次 \(p.skippedBatchDuplicates) / 文件 \(p.skippedFileDuplicates)）")
                        Text("解析失败：\(p.parseFailures.count)")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    TextEditor(text: .constant(p.previewText))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140, maxHeight: 220)
                        .disabled(true)
                } else {
                    Text("暂无导出预览。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resultSection: some View {
        GroupBox("结果") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("打开输出目录") { vm.openOutputFolderInFinder() }
                        .disabled(vm.vaultURL == nil)

                    Button("打开导入索引") { vm.openIndexFile() }
                        .disabled(vm.vaultURL == nil)

                    Button("打开日志") { vm.openLogFile() }
                        .disabled(vm.vaultURL == nil)

                    Spacer()
                }
                .font(.footnote)

                TextEditor(text: $vm.importSummary)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
            }
        }
    }
}

private func severityLabel(_ s: WarningSeverity) -> String {
    switch s {
    case .info: return "信息"
    case .warning: return "警告"
    case .error: return "错误"
    }
}

private func severityColor(_ s: WarningSeverity) -> Color {
    switch s {
    case .info: return .secondary
    case .warning: return .orange
    case .error: return .red
    }
}
