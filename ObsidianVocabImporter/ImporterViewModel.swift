import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImporterViewModel: ObservableObject {
    @Published var vaultURL: URL? = nil {
        didSet {
            persistURLPath(vaultURL, key: RecentSelectionKeys.lastVaultPath)
            momoPreview = nil
        }
    }
    @Published var sentenceCSVURL: URL? = nil {
        didSet { persistURLPath(sentenceCSVURL, key: RecentSelectionKeys.lastSentenceCSVPath) }
    }
    @Published var vocabCSVURL: URL? = nil {
        didSet {
            persistURLPath(vocabCSVURL, key: RecentSelectionKeys.lastVocabCSVPath)
            momoPreview = nil
        }
    }
    @Published var mode: ImportMode = .merged {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: RecentSelectionKeys.lastImportMode) }
    }

    @Published var preparedPlan: PreparedImportPlan?

    @Published var isWorking: Bool = false
    @Published var progress: Double = 0
    @Published var statusText: String = ""
    @Published var lastError: String?

    @Published var importSummary: String = ""
    @Published var momoPreview: MomoExportPreview?
    @Published var pendingColumnMapping: PendingColumnMapping?

    private var scheduledRefreshTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var momoPreviewTask: Task<Void, Never>?
    private var momoExportTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    private enum WorkKind {
        case preview
        case `import`
        case momoExport
        case maintenance
    }

    private var workKind: WorkKind?
    private var activePreviewToken: UUID = UUID()
    private var pendingPreviewRefreshAfterWork: Bool = false
    private var lastKnownPreferences: PreferencesSnapshot = PreferencesSnapshot.load()

    init() {
        let defaults = UserDefaults.standard
        let fm = FileManager.default

        if let rawMode = defaults.string(forKey: RecentSelectionKeys.lastImportMode),
           let m = ImportMode(rawValue: rawMode) {
            mode = m
        }

        if let vaultPath = defaults.string(forKey: RecentSelectionKeys.lastVaultPath) {
            let url = URL(fileURLWithPath: vaultPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                vaultURL = url
            }
        }

        if let sentencePath = defaults.string(forKey: RecentSelectionKeys.lastSentenceCSVPath) {
            let url = URL(fileURLWithPath: sentencePath, isDirectory: false)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                sentenceCSVURL = url
            }
        }

        if let vocabPath = defaults.string(forKey: RecentSelectionKeys.lastVocabCSVPath) {
            let url = URL(fileURLWithPath: vocabPath, isDirectory: false)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                vocabCSVURL = url
            }
        }

        // If all required inputs are already available (e.g. restoring last session), auto-generate a preview.
        if missingInputHint == nil {
            schedulePreviewRefresh()
        }
    }

    func handleUserDefaultsDidChange() {
        // UserDefaults can change for many reasons (e.g. window frame autosave during dragging).
        // Only refresh the import preview when our own preferences actually change; otherwise the
        // app can feel janky when moving/resizing the window.
        let now = PreferencesSnapshot.load()
        guard now != lastKnownPreferences else { return }
        lastKnownPreferences = now
        schedulePreviewRefresh()
    }

    var missingInputHint: String? {
        guard vaultURL != nil else { return "请选择 Obsidian Vault 文件夹开始。" }

        switch mode {
        case .sentences:
            return sentenceCSVURL == nil ? "句子模式需要选择句子 CSV。" : nil
        case .vocabulary:
            return vocabCSVURL == nil ? "词汇模式需要选择词汇 CSV。" : nil
        case .merged:
            if sentenceCSVURL == nil || vocabCSVURL == nil {
                return "全部合并模式需要同时选择句子 CSV 和词汇 CSV。"
            }
            return nil
        }
    }

    var canImport: Bool {
        missingInputHint == nil && preparedPlan != nil && (preparedPlan?.hasBlockingWarnings == false)
    }

    var canMomoExport: Bool {
        vaultURL != nil
    }

    private func persistURLPath(_ url: URL?, key: String) {
        let defaults = UserDefaults.standard
        guard let url else {
            defaults.removeObject(forKey: key)
            return
        }

        let standardized = url.standardizedFileURL
        defaults.set(standardized.path, forKey: key)
    }

    // Convenience actions for debugging and real-world workflows.
    func openOutputFolderInFinder() {
        guard let vaultURL else { return }
        let prefs = PreferencesSnapshot.load()
        let root = vaultURL.appendingPathComponent(prefs.outputRootRelativePath, isDirectory: true)

        // Don't create folders eagerly unless the user asks to open them.
        if !FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                lastError = "无法创建输出目录：\(root.path)\n\(error.localizedDescription)"
                return
            }
        }
        NSWorkspace.shared.open(root)
    }

    func openIndexFile() {
        guard let vaultURL else { return }
        let store = ImportedIndexStore(vaultURL: vaultURL)
        let fm = FileManager.default
        if fm.fileExists(atPath: store.indexURL.path) {
            NSWorkspace.shared.open(store.indexURL)
            return
        }
        if fm.fileExists(atPath: store.legacyIndexURL.path) {
            NSWorkspace.shared.open(store.legacyIndexURL)
            return
        }
        lastError = "索引文件不存在：还没有进行过导入。"
    }

    func openLogFile() {
        guard let vaultURL else { return }
        let logger = ImportLogger(vaultURL: vaultURL)
        let fm = FileManager.default
        if fm.fileExists(atPath: logger.logURL.path) {
            NSWorkspace.shared.open(logger.logURL)
            return
        }
        if fm.fileExists(atPath: logger.legacyLogURL.path) {
            NSWorkspace.shared.open(logger.legacyLogURL)
            return
        }
        lastError = "日志文件不存在：尚未产生解析失败或写入错误。"
    }

    func openMomoExportIndexFile() {
        guard let vaultURL else { return }
        let store = MomoExportIndexStore(vaultURL: vaultURL)
        let fm = FileManager.default
        if fm.fileExists(atPath: store.indexURL.path) {
            NSWorkspace.shared.open(store.indexURL)
            return
        }
        if fm.fileExists(atPath: store.legacyIndexURL.path) {
            NSWorkspace.shared.open(store.legacyIndexURL)
            return
        }
        lastError = "墨墨导出索引不存在：还没有进行过导出。"
    }

    func schedulePreviewRefresh() {
        scheduledRefreshTask?.cancel()

        // Invalidate any in-flight preview so it can't publish a stale plan after inputs change.
        activePreviewToken = UUID()

        preparedPlan = nil // Prevent importing with a stale preview after inputs change.
        lastError = nil
        pendingColumnMapping = nil

        // If a preview is already running, cancel it early to avoid wasting CPU on a stale parse.
        if workKind == .preview {
            prepareTask?.cancel()
            prepareTask = nil
            isWorking = false
            workKind = nil
            statusText = ""
            progress = 0
        }

        // If we're currently importing/exporting/maintaining, don't start a preview task that could clobber progress.
        if workKind == .import || workKind == .momoExport || workKind == .maintenance {
            pendingPreviewRefreshAfterWork = true
            return
        }

        statusText = ""
        progress = 0

        // If inputs are incomplete, don't schedule a preview.
        guard missingInputHint == nil else { return }

        scheduledRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.preparePreview()
        }
    }

    func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK {
            vaultURL = panel.url
        }
    }

    func chooseSentenceCSV() {
        chooseCSV { [weak self] url in
            self?.sentenceCSVURL = url
        }
    }

    func chooseVocabularyCSV() {
        chooseCSV { [weak self] url in
            self?.vocabCSVURL = url
        }
    }

    private func chooseCSV(onPick: (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText]

        if panel.runModal() == .OK {
            onPick(panel.url)
        }
    }

    func handleDrop(providers: [NSItemProvider]) {
        for p in providers {
            guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let self else { return }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task { @MainActor in
                    self.assignDroppedCSV(url)
                }
            }
        }
    }

    private func assignDroppedCSV(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "csv" || ext == "txt" else { return }

        Task.detached { [weak self] in
            guard let self else { return }
            let kind = CSVKind.detect(url: url)
            await MainActor.run {
                switch kind {
                case .sentence:
                    self.sentenceCSVURL = url
                case .vocabulary:
                    self.vocabCSVURL = url
                case .unknown:
                    // Heuristic fallback: prefer filling the missing one.
                    if self.sentenceCSVURL == nil {
                        self.sentenceCSVURL = url
                    } else if self.vocabCSVURL == nil {
                        self.vocabCSVURL = url
                    }
                }
            }
        }
    }

    func preparePreview() {
        prepareTask?.cancel()

        guard missingInputHint == nil else {
            preparedPlan = nil
            return
        }
        guard let vaultURL else { return }

        let sentenceURL = sentenceCSVURL
        let vocabURL = vocabCSVURL
        let mode = mode

        workKind = .preview
        let token = UUID()
        activePreviewToken = token

        isWorking = true
        progress = 0
        statusText = "正在生成预览…"
        lastError = nil
        pendingColumnMapping = nil

        prepareTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let vm = self else { return }
            do {
                let plan = try ImportPlanner.preparePlan(
                    vaultURL: vaultURL,
                    sentenceCSVURL: sentenceURL,
                    vocabCSVURL: vocabURL,
                    mode: mode,
                    progress: { p, msg in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            guard vm.activePreviewToken == token else { return }
                            vm.progress = p
                            vm.statusText = msg
                        }
                    }
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard vm.activePreviewToken == token else { return }
                    vm.preparedPlan = plan
                    vm.statusText = plan.days.isEmpty ? "没有可导入的新条目（全部重复或解析失败）。" : "预览就绪，可以导入。"
                    vm.progress = 1.0
                    vm.isWorking = false
                    vm.workKind = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard vm.activePreviewToken == token else { return }
                    vm.preparedPlan = nil
                    if let e = error as? ImportPlannerError, case let .needsColumnMapping(pending) = e {
                        vm.pendingColumnMapping = pending
                        vm.lastError = nil
                        vm.statusText = "需要列映射才能继续预览。"
                        vm.progress = 0
                        vm.isWorking = false
                        vm.workKind = nil
                    } else {
                        vm.lastError = "预览失败：\(error.localizedDescription)"
                        vm.statusText = ""
                        vm.progress = 0
                        vm.isWorking = false
                        vm.workKind = nil
                    }
                }
            }
        }
    }

    func performImport() {
        importTask?.cancel()

        guard let vaultURL else {
            lastError = "缺少 Vault 文件夹。"
            return
        }
        guard let plan = preparedPlan else {
            lastError = "暂无预览，请先点击“刷新预览”。"
            return
        }
        guard !plan.hasBlockingWarnings else {
            lastError = "存在错误预警：为避免写乱笔记，已禁用导入。请先修复预警问题，或仅预览不写入。"
            return
        }

        workKind = .import
        isWorking = true
        progress = 0
        statusText = "正在导入…"
        lastError = nil

        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let vm = self else { return }
            do {
                let summary = try ImportPlanner.performImport(
                    plan: plan,
                    vaultURL: vaultURL,
                    progress: { p, msg in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            vm.progress = p
                            vm.statusText = msg
                        }
                    }
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.importSummary = summary
                    vm.statusText = "导入完成。"
                    vm.progress = 1.0
                    vm.isWorking = false
                    vm.workKind = nil

                    // Refresh preview so counts reflect dedup index growth.
                    // If inputs changed during import/export, we delayed the refresh until now.
                    vm.pendingPreviewRefreshAfterWork = false
                    vm.schedulePreviewRefresh()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.lastError = "导入失败：\(error.localizedDescription)"
                    vm.statusText = ""
                    vm.progress = 0
                    vm.isWorking = false
                    vm.workKind = nil

                    if vm.pendingPreviewRefreshAfterWork {
                        vm.pendingPreviewRefreshAfterWork = false
                        vm.schedulePreviewRefresh()
                    }
                }
            }
        }
    }

    // MARK: - MoMo Export

    func prepareMomoExportPreview() {
        momoPreviewTask?.cancel()
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        momoPreview = nil
        lastError = nil

        guard let vaultURL else {
            lastError = "缺少 Vault 文件夹（用于保存墨墨导出索引）。"
            return
        }
        let prefs = PreferencesSnapshot.load()

        workKind = .momoExport
        isWorking = true
        progress = 0
        statusText = "正在生成墨墨导出预览…"

        momoPreviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let vm = self else { return }
            do {
                let preview = try MomoWordExporter.preparePreviewFromVault(
                    vaultURL: vaultURL,
                    preferences: prefs,
                    destination: nil,
                    progress: { p in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            vm.progress = p
                            vm.statusText = "正在生成墨墨导出预览…"
                        }
                    }
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.momoPreview = preview
                    vm.statusText = preview.wordCount == 0 ? "没有可导出的新单词（全部重复或解析失败）。" : "墨墨导出预览就绪。"
                    vm.progress = 1.0
                    vm.isWorking = false
                    vm.workKind = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.lastError = "墨墨导出预览失败：\(error.localizedDescription)"
                    vm.statusText = ""
                    vm.progress = 0
                    vm.isWorking = false
                    vm.workKind = nil
                }
            }
        }
    }

    func copyMomoWordsToClipboard() {
        momoExportTask?.cancel()
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        lastError = nil

        guard let vaultURL else {
            lastError = "缺少 Vault 文件夹（用于保存墨墨导出索引）。"
            return
        }
        let prefs = PreferencesSnapshot.load()

        workKind = .momoExport
        isWorking = true
        progress = 0
        statusText = "正在导出到剪贴板…"

        momoExportTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let vm = self else { return }
            do {
                let summary = try MomoWordExporter.exportFromVault(
                    vaultURL: vaultURL,
                    preferences: prefs,
                    destination: .clipboard,
                    progress: { p in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            vm.progress = p
                            vm.statusText = "正在导出到剪贴板…"
                        }
                    }
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.importSummary = summary
                    vm.statusText = "墨墨导出完成（已复制到剪贴板）。"
                    vm.progress = 1.0
                    vm.isWorking = false
                    vm.workKind = nil

                    if vm.pendingPreviewRefreshAfterWork {
                        vm.pendingPreviewRefreshAfterWork = false
                        vm.schedulePreviewRefresh()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.lastError = "墨墨导出失败：\(error.localizedDescription)"
                    vm.statusText = ""
                    vm.progress = 0
                    vm.isWorking = false
                    vm.workKind = nil
                }
            }
        }
    }

    func exportMomoWordsToTXT() {
        momoExportTask?.cancel()
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        lastError = nil

        guard let vaultURL else {
            lastError = "缺少 Vault 文件夹（用于保存墨墨导出索引）。"
            return
        }
        let prefs = PreferencesSnapshot.load()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "导出墨墨单词本（纯单词）"
        panel.nameFieldStringValue = "momo_words.txt"
        panel.allowedContentTypes = [UTType.plainText]
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else {
            return
        }

        workKind = .momoExport
        isWorking = true
        progress = 0
        statusText = "正在导出到文件…"

        momoExportTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let vm = self else { return }
            do {
                let summary = try MomoWordExporter.exportFromVault(
                    vaultURL: vaultURL,
                    preferences: prefs,
                    destination: .file(dest),
                    progress: { p in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            vm.progress = p
                            vm.statusText = "正在导出到文件…"
                        }
                    }
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.importSummary = summary
                    vm.statusText = "墨墨导出完成。"
                    vm.progress = 1.0
                    vm.isWorking = false
                    vm.workKind = nil

                    if vm.pendingPreviewRefreshAfterWork {
                        vm.pendingPreviewRefreshAfterWork = false
                        vm.schedulePreviewRefresh()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.lastError = "墨墨导出失败：\(error.localizedDescription)"
                    vm.statusText = ""
                    vm.progress = 0
                    vm.isWorking = false
                    vm.workKind = nil
                }
            }
        }
    }

    // MARK: - Maintenance / Scan

    func scanAndArchiveMastered(previewOnly: Bool) {
        maintenanceTask?.cancel()
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        lastError = nil
        momoPreview = nil

        guard let vaultURL else {
            lastError = "缺少 Vault 文件夹。"
            return
        }

        let prefs = PreferencesSnapshot.load()
        let outputRoot = vaultURL.appendingPathComponent(prefs.outputRootRelativePath, isDirectory: true)

        workKind = .maintenance
        isWorking = true
        progress = 0
        statusText = previewOnly ? "正在扫描（预览）…" : "正在扫描并归档…"

        maintenanceTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let vm = self else { return }

            func readTextFileLossy(_ url: URL) -> String? {
                do {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
                    for enc in encodings {
                        if let s = String(data: data, encoding: enc) {
                            return s
                        }
                    }
                    return nil
                } catch {
                    return nil
                }
            }

            let fm = FileManager.default
            guard fm.fileExists(atPath: outputRoot.path) else {
                await MainActor.run {
                    vm.importSummary = "维护摘要\n- 输出目录不存在：\(outputRoot.path)\n"
                    vm.statusText = "扫描完成。"
                    vm.progress = 1.0
                    vm.isWorking = false
                    vm.workKind = nil
                }
                return
            }

            var files: [URL] = []
            if let e = fm.enumerator(at: outputRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                while let u = e.nextObject() as? URL {
                    if u.pathExtension.lowercased() == "md" {
                        files.append(u)
                    }
                }
            }

            files.sort { $0.path < $1.path }
            let totalFiles = files.count

            var changedFiles: [String] = []
            changedFiles.reserveCapacity(32)
            var movedV = 0
            var movedS = 0
            var unreadable = 0
            var writeFailed = 0

            let logger = ImportLogger(vaultURL: vaultURL)
            var logLines: [String] = []

            func relativePath(from base: URL, to file: URL) -> String {
                let basePath = base.standardizedFileURL.path
                let filePath = file.standardizedFileURL.path
                if filePath.hasPrefix(basePath + "/") {
                    return String(filePath.dropFirst(basePath.count + 1))
                }
                return file.lastPathComponent
            }

            for (idx, fileURL) in files.enumerated() {
                guard !Task.isCancelled else { return }
                let p = Double(idx) / Double(max(totalFiles, 1))
                let status = (previewOnly ? "正在扫描（预览）…" : "正在扫描并归档…") + "  (\(idx + 1)/\(totalFiles))"
                await MainActor.run {
                    vm.progress = p
                    vm.statusText = status
                }

                guard let text = readTextFileLossy(fileURL) else {
                    unreadable += 1
                    logLines.append("无法读取 Markdown（编码未知）：\(relativePath(from: vaultURL, to: fileURL))")
                    continue
                }

                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                let result = MarkdownUpdater.archiveMastered(existing: normalized, preferences: prefs)
                let updated = result.updatedMarkdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

                if updated != normalized {
                    movedV += result.movedVocabIDs.count
                    movedS += result.movedSentenceIDs.count
                    changedFiles.append(relativePath(from: vaultURL, to: fileURL))

                    if !previewOnly {
                        do {
                            try AtomicFileWriter.writeString(result.updatedMarkdown, to: fileURL)
                        } catch {
                            writeFailed += 1
                            logLines.append("归档写入失败（\(relativePath(from: vaultURL, to: fileURL))）：\(error.localizedDescription)")
                        }
                    }
                }
            }

            if !logLines.isEmpty {
                try? logger.appendSession(title: "Maintenance Scan", lines: logLines)
            }

            var summary = "维护摘要（已掌握归档）\n"
            summary += "- 扫描文件：\(totalFiles)\n"
            summary += "- 需要变更：\(changedFiles.count)\n"
            summary += "- 移动到 Mastered：词汇 \(movedV) / 句子 \(movedS)\n"
            summary += "- 无法读取：\(unreadable)\n"
            if !previewOnly {
                summary += "- 写入失败：\(writeFailed)\n"
            }
            if !changedFiles.isEmpty {
                summary += "- 示例文件：\n"
                for name in changedFiles.prefix(10) {
                    summary += "  - \(name)\n"
                }
                if changedFiles.count > 10 {
                    summary += "  - …（共 \(changedFiles.count) 个）\n"
                }
            }

            let summaryText = summary
            await MainActor.run {
                vm.importSummary = summaryText
                vm.statusText = "扫描完成。"
                vm.progress = 1.0
                vm.isWorking = false
                vm.workKind = nil

                if vm.pendingPreviewRefreshAfterWork {
                    vm.pendingPreviewRefreshAfterWork = false
                    vm.schedulePreviewRefresh()
                }
            }
        }
    }

    func applyColumnMapping(_ mapping: ColumnMapping) {
        ColumnMappingStore.save(mapping)
    }
}

// MARK: - Planner / Import Engine

enum WarningSeverity: String, Sendable {
    case info
    case warning
    case error
}

struct ImportWarning: Identifiable, Sendable {
    let id = UUID()
    let severity: WarningSeverity
    let title: String
    let detail: String?
    let relatedPath: String?
}

struct PreparedImportPlan: Identifiable, Sendable {
    let id = UUID()
    let preferences: PreferencesSnapshot
    let mode: ImportMode
    let days: [PreparedDayPlan]
    let parseFailures: [ParseFailure]
    let warnings: [ImportWarning]
    let skippedIndexDuplicates: Int
    let skippedBatchDuplicates: Int
    let skippedFileDuplicates: Int
    let observedExistingSentenceIDs: Set<String>
    let observedExistingVocabIDs: Set<String>

    var totalNewSentences: Int {
        days.reduce(0) { $0 + $1.appendedSentenceIDs.count }
    }

    var totalNewVocab: Int {
        days.reduce(0) { $0 + $1.appendedVocabIDs.count }
    }

    var totalNewItems: Int { totalNewSentences + totalNewVocab }
    var skippedDuplicatesTotal: Int { skippedIndexDuplicates + skippedBatchDuplicates + skippedFileDuplicates }
    var parseFailuresCount: Int { parseFailures.count }

    var hasBlockingWarnings: Bool {
        warnings.contains(where: { $0.severity == .error })
    }
}

struct PreparedDayPlan: Identifiable, Sendable {
    var id: String { date }

    let date: String
    let outputURL: URL
    let relativeOutputPath: String
    let markdownPreview: String
    let newSentences: [SentenceClip]
    let newVocab: [VocabClip]
    let appendedSentenceIDs: [String]
    let appendedVocabIDs: [String]
}

enum ImportPlannerError: Error, LocalizedError {
    case needsColumnMapping(PendingColumnMapping)

    var errorDescription: String? {
        switch self {
        case .needsColumnMapping(let pending):
            return "需要为 \(pending.kind.displayName) CSV 选择列映射后才能继续。"
        }
    }
}

enum ImportPlanner {
    // progress is (0...1, message)
    static func preparePlan(
        vaultURL: URL,
        sentenceCSVURL: URL?,
        vocabCSVURL: URL?,
        mode: ImportMode,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> PreparedImportPlan {
        func readTextFileLossy(_ url: URL) -> String? {
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
                for enc in encodings {
                    if let s = String(data: data, encoding: enc) {
                        return s
                    }
                }
                return nil
            } catch {
                return nil
            }
        }

        let prefs = PreferencesSnapshot.load()
        let fm = FileManager.default

        var warnings: [ImportWarning] = []
        warnings.reserveCapacity(8)
        var warningKeys: Set<String> = []

        func addWarning(_ severity: WarningSeverity, _ title: String, _ detail: String? = nil, path: String? = nil) {
            let key = "\(severity.rawValue)|\(title)|\(path ?? "")"
            guard !warningKeys.contains(key) else { return }
            warningKeys.insert(key)
            warnings.append(ImportWarning(severity: severity, title: title, detail: detail, relatedPath: path))
        }

        // Basic conflict pre-checks: allow preview even if not writable, but block import later.
        if !fm.isWritableFile(atPath: vaultURL.path) {
            addWarning(.error, "Vault 不可写", "当前用户对该目录没有写权限，导入会失败。请检查权限/磁盘空间，或选择其它 Vault。", path: vaultURL.path)
        }

        let outputRoot = vaultURL.appendingPathComponent(prefs.outputRootRelativePath, isDirectory: true)
        var rootIsDir: ObjCBool = false
        if fm.fileExists(atPath: outputRoot.path, isDirectory: &rootIsDir), !rootIsDir.boolValue {
            addWarning(.error, "输出根目录被同名文件占用", "在 Vault 内发现同名文件：\(prefs.outputRootRelativePath)。需要删除/改名该文件，或在偏好设置中更换输出根目录名。", path: outputRoot.path)
        }

        progress?(0.02, "加载索引…")
        let indexStore = ImportedIndexStore(vaultURL: vaultURL)
        var index = try indexStore.load()

        // Best-effort self-heal when the index is missing/corrupted/incomplete:
        // - We scan existing importer Markdown under the output root and treat their IDs as already imported.
        // - This prevents cross-day duplicates even if imported_index.json was deleted or became corrupt.
        // - It also protects against "valid but incomplete" indexes (e.g. sync conflicts or accidental overwrites
        //   that reset imported_index.json to an empty-but-valid JSON), which would otherwise allow cross-day duplicates.
        //
        // We intentionally do not write the rebuilt index during preview (preparePlan) to honor "preview-only".
        // The rebuilt IDs are carried in the plan so performImport can persist them afterwards.
        var observedExistingSentenceIDs: Set<String> = []
        var observedExistingVocabIDs: Set<String> = []

        let primaryIndexExists = fm.fileExists(atPath: indexStore.indexURL.path)
        let legacyIndexExists = fm.fileExists(atPath: indexStore.legacyIndexURL.path)

        enum IndexSelfHealReason {
            case missingPrimary
            case incomplete
        }

        var outputIsDir: ObjCBool = false
        if fm.fileExists(atPath: outputRoot.path, isDirectory: &outputIsDir), outputIsDir.boolValue {
            // If a legacy index exists, a full scan is often unnecessary. We do a lightweight
            // sampling scan first; only when we detect IDs not present in the index do we
            // escalate to a full scan.
            let sampleLimit = 30

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

            func scanFiles(_ files: [URL], into sentences: inout Set<String>, _ vocab: inout Set<String>, unreadable: inout Int) {
                for u in files {
                    guard let text = readTextFileLossy(u) else {
                        unreadable += 1
                        continue
                    }
                    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    let (sids, vids) = MarkdownUpdater.extractIDs(from: normalized)
                    sentences.formUnion(sids)
                    vocab.formUnion(vids)
                }
            }

            var needsFullScan = false
            var healReason: IndexSelfHealReason?

            if !primaryIndexExists {
                // Correctness over performance: if the primary index is missing, we always scan existing notes
                // (under the app-managed output root) to avoid cross-day duplicates.
                needsFullScan = true
                healReason = .missingPrimary
            } else {
                // Primary index exists, but it might be incomplete (e.g. sync conflicts overwrote it).
                // Sample a few Markdown files: if they contain IDs not present in the index, do a full scan.
                let sampleFiles = enumerateMarkdownFiles(limit: sampleLimit)
                if !sampleFiles.isEmpty {
                    progress?(0.03, "抽样校验索引…")
                    var sampleS: Set<String> = []
                    var sampleV: Set<String> = []
                    var unreadable = 0
                    scanFiles(sampleFiles, into: &sampleS, &sampleV, unreadable: &unreadable)

                    let unknownS = sampleS.subtracting(index.sentences)
                    let unknownV = sampleV.subtracting(index.vocab)
                    if !unknownS.isEmpty || !unknownV.isEmpty {
                        needsFullScan = true
                        healReason = .incomplete
                    }
                }
            }

            if needsFullScan {
                let msg: String
                switch healReason {
                case .missingPrimary:
                    msg = "索引缺失，扫描现有 Markdown…"
                case .incomplete:
                    msg = "索引不完整，扫描现有 Markdown…"
                case .none:
                    msg = "扫描现有 Markdown…"
                }
                progress?(0.03, msg)

                var scannedS: Set<String> = []
                var scannedV: Set<String> = []
                scannedS.reserveCapacity(1024)
                scannedV.reserveCapacity(1024)

                var unreadable = 0
                // Stream the scan to avoid holding a large list of URLs in memory.
                if let e = fm.enumerator(at: outputRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let u as URL in e {
                        if u.pathExtension.lowercased() != "md" { continue }
                        guard let text = readTextFileLossy(u) else {
                            unreadable += 1
                            continue
                        }
                        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                        let (sids, vids) = MarkdownUpdater.extractIDs(from: normalized)
                        scannedS.formUnion(sids)
                        scannedV.formUnion(vids)
                    }
                }

                if !scannedS.isEmpty || !scannedV.isEmpty {
                    index.sentences.formUnion(scannedS)
                    index.vocab.formUnion(scannedV)

                    // Carry these IDs so performImport can persist them back into imported_index.json.
                    observedExistingSentenceIDs.formUnion(scannedS)
                    observedExistingVocabIDs.formUnion(scannedV)

                    switch healReason {
                    case .missingPrimary:
                        let detail: String
                        if legacyIndexExists {
                            detail = "已合并旧索引，并从现有 Markdown 全量扫描用于补全查重；导入完成后会自动生成新索引文件 imported_index.json。"
                        } else {
                            detail = "已从现有 Markdown 全量扫描用于查重；导入完成后会自动生成新索引文件 imported_index.json。"
                        }
                        addWarning(.info, "索引缺失，已从现有 Markdown 扫描用于查重", detail, path: indexStore.indexURL.path)

                    case .incomplete:
                        addWarning(
                            .warning,
                            "索引可能不完整，已从现有 Markdown 扫描用于查重",
                            "检测到 \(VaultSupportPaths.importedIndexFileName) 未包含部分已写入的条目 id（可能是同步冲突、覆盖或手动编辑导致）。本次预览已通过扫描现有 Markdown 补全查重；导入完成后会自动更新索引文件。",
                            path: indexStore.indexURL.path
                        )

                    case .none:
                        break
                    }

                    if unreadable > 0 {
                        addWarning(.warning, "索引扫描中有文件无法读取", "有 \(unreadable) 个 Markdown 无法按常见编码读取（不会影响其它文件的查重）。", path: outputRoot.path)
                    }
                }
            }
        }

        var parseFailures: [ParseFailure] = []
        var skippedIndexDuplicates = 0
        var skippedBatchDuplicates = 0

        // Parse sentences (for import and/or for year completion).
        var sentenceClips: [SentenceClip] = []
        var yearCounts: [Int: Int] = [:]

        let sentenceParseRequired = (mode == .sentences || mode == .merged)
        let needSentenceParse = sentenceParseRequired ||
            (prefs.yearCompletionStrategy == .mostCommonSentenceYear && sentenceCSVURL != nil)

        if needSentenceParse, let sentenceCSVURL {
            do {
                let cfg = try resolveCSVImportConfig(url: sentenceCSVURL, kind: .sentence, required: sentenceParseRequired)
                progress?(0.05, "解析句子 CSV…")
                let parsed = try parseSentenceCSV(url: sentenceCSVURL, config: cfg, existingIndex: index, progress: { p in
                    progress?(0.05 + 0.35 * p, "解析句子 CSV…")
                })
                sentenceClips = parsed.newItems
                parseFailures.append(contentsOf: parsed.failures)
                skippedIndexDuplicates += parsed.skippedIndexDuplicates
                skippedBatchDuplicates += parsed.skippedBatchDuplicates
                yearCounts = parsed.yearCounts
            } catch {
                // Sentence CSV is optional when only used for "most common sentence year" fallback.
                // In that case, any parse failure should degrade gracefully to system-year completion.
                if !sentenceParseRequired {
                    if let e = error as? ImportPlannerError, case .needsColumnMapping = e {
                        addWarning(.warning, "句子 CSV 表头无法识别", "用于年份补全的句子 CSV 无法自动识别列名，已回退到系统年份。你可以在“全部合并/句子模式”下导入一次并完成列映射。", path: sentenceCSVURL.lastPathComponent)
                    } else {
                        addWarning(.warning, "句子 CSV 解析失败（已回退到系统年份）", error.localizedDescription, path: sentenceCSVURL.lastPathComponent)
                    }
                    sentenceClips = []
                    yearCounts = [:]
                } else {
                    throw error
                }
            }
        }

        let systemYear = Calendar.current.component(.year, from: Date())
        let fallbackYear: Int
        switch prefs.yearCompletionStrategy {
        case .systemYear:
            fallbackYear = systemYear
        case .mostCommonSentenceYear:
            if let mostCommon = yearCounts.max(by: { $0.value < $1.value })?.key {
                fallbackYear = mostCommon
            } else {
                fallbackYear = systemYear
            }
        }

        // Parse vocabulary.
        var vocabClips: [VocabClip] = []
        if mode == .vocabulary || mode == .merged {
            guard let vocabCSVURL else {
                throw NSError(domain: "OEI", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少词汇 CSV。"])
            }
            let cfg = try resolveCSVImportConfig(url: vocabCSVURL, kind: .vocabulary, required: true)
            progress?(0.45, "解析词汇 CSV…")
            let parsed = try parseVocabCSV(url: vocabCSVURL, config: cfg, fallbackYear: fallbackYear, existingIndex: index, progress: { p in
                progress?(0.45 + 0.35 * p, "解析词汇 CSV…")
            })
            vocabClips = parsed.newItems
            parseFailures.append(contentsOf: parsed.failures)
            skippedIndexDuplicates += parsed.skippedIndexDuplicates
            skippedBatchDuplicates += parsed.skippedBatchDuplicates
        }

        // Group by date.
        let sentencesByDate = Dictionary(grouping: sentenceClips, by: { $0.date })
        let vocabByDate = Dictionary(grouping: vocabClips, by: { $0.date })

        let candidateDates: [String]
        switch mode {
        case .sentences:
            candidateDates = Array(sentencesByDate.keys)
        case .vocabulary:
            candidateDates = Array(vocabByDate.keys)
        case .merged:
            let all = Set(sentencesByDate.keys).union(vocabByDate.keys)
            candidateDates = Array(all)
        }

        let sortedDates = candidateDates.sorted()

        var days: [PreparedDayPlan] = []
        days.reserveCapacity(sortedDates.count)

        var skippedFileDuplicates = 0
        let largeDayThreshold = 600 // heuristic: warn when a single day file becomes very large

        for (idx, date) in sortedDates.enumerated() {
            progress?(0.82 + 0.18 * Double(idx) / Double(max(sortedDates.count, 1)), "生成 Markdown 预览…")

            let outputURL = outputFileURL(vaultURL: vaultURL, prefs: prefs, date: date)
            let relPath = relativePath(from: vaultURL, to: outputURL)

            // Pre-check writability / potential conflicts.
            let outDir = outputURL.deletingLastPathComponent()
            if fm.fileExists(atPath: outDir.path) {
                if !fm.isWritableFile(atPath: outDir.path) {
                    addWarning(.error, "输出目录不可写", "无法写入该日期文件所在目录。", path: relPath)
                }
            }
            if fm.fileExists(atPath: outputURL.path) {
                if !fm.isWritableFile(atPath: outputURL.path) {
                    addWarning(.error, "目标文件不可写", "文件没有写权限，导入会失败。", path: relPath)
                } else {
                    // Best-effort: if FileHandle for writing fails, it's often because the file is locked or in use.
                    do {
                        let fh = try FileHandle(forWritingTo: outputURL)
                        try fh.close()
                    } catch {
                        addWarning(.warning, "文件可能被占用", "\(error.localizedDescription)", path: relPath)
                    }
                }
            }

            let existing: String?
            if FileManager.default.fileExists(atPath: outputURL.path) {
                existing = readTextFileLossy(outputURL)
                if existing == nil {
                    parseFailures.append(ParseFailure(fileName: relPath, lineNumber: 0, reason: "无法读取现有 Markdown 文件（编码未知），为安全起见已跳过此日期文件。"))
                    continue
                }
            } else {
                existing = nil
            }
            let existingNormalized = existing?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

            if let existingNormalized {
                let (sids, vids) = MarkdownUpdater.extractIDs(from: existingNormalized)
                observedExistingSentenceIDs.formUnion(sids)
                observedExistingVocabIDs.formUnion(vids)

                let total = sids.count + vids.count
                if total >= largeDayThreshold {
                    addWarning(.warning, "同一天文件内容较多", "该日期文件已包含 \(total) 条记录。建议定期勾选已掌握条目并使用“自动归档/扫描归档”保持可读性。", path: relPath)
                }
            }

            let newS = sentencesByDate[date] ?? []
            let newV = vocabByDate[date] ?? []

            let update = MarkdownUpdater.update(
                existing: existingNormalized,
                date: date,
                mode: mode,
                newSentences: newS,
                newVocab: newV,
                preferences: prefs,
                frontmatterSource: "imported"
            )

            skippedFileDuplicates += (newS.count - update.appendedSentences.count)
            skippedFileDuplicates += (newV.count - update.appendedVocab.count)

            let updatedNormalized = update.updatedMarkdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let shouldInclude: Bool
            if let existingNormalized {
                shouldInclude = updatedNormalized != existingNormalized
            } else {
                // Only create a new file when we have new entries; avoid creating empty notes.
                shouldInclude = !update.appendedSentences.isEmpty || !update.appendedVocab.isEmpty
            }
            guard shouldInclude else { continue }

            days.append(
                PreparedDayPlan(
                    date: date,
                    outputURL: outputURL,
                    relativeOutputPath: relPath,
                    markdownPreview: update.updatedMarkdown,
                    newSentences: newS,
                    newVocab: newV,
                    appendedSentenceIDs: update.appendedSentences.map { $0.id },
                    appendedVocabIDs: update.appendedVocab.map { $0.id }
                )
            )
        }

        progress?(1.0, "预览就绪")

        return PreparedImportPlan(
            preferences: prefs,
            mode: mode,
            days: days,
            parseFailures: parseFailures,
            warnings: warnings.sorted { a, b in
                if a.severity != b.severity {
                    // error > warning > info
                    let rank: (WarningSeverity) -> Int = { s in
                        switch s { case .error: return 0; case .warning: return 1; case .info: return 2 }
                    }
                    return rank(a.severity) < rank(b.severity)
                }
                return a.title < b.title
            },
            skippedIndexDuplicates: skippedIndexDuplicates,
            skippedBatchDuplicates: skippedBatchDuplicates,
            skippedFileDuplicates: skippedFileDuplicates,
            observedExistingSentenceIDs: observedExistingSentenceIDs,
            observedExistingVocabIDs: observedExistingVocabIDs
        )
    }

    static func performImport(
        plan: PreparedImportPlan,
        vaultURL: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> String {
        func readTextFileLossy(_ url: URL) -> String? {
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
                for enc in encodings {
                    if let s = String(data: data, encoding: enc) {
                        return s
                    }
                }
                return nil
            } catch {
                return nil
            }
        }

        let indexStore = ImportedIndexStore(vaultURL: vaultURL)
        var index = try indexStore.load()

        // Self-heal: if files already contain IDs (but index is missing), merge them in.
        index.sentences.formUnion(plan.observedExistingSentenceIDs)
        index.vocab.formUnion(plan.observedExistingVocabIDs)

        let logger = ImportLogger(vaultURL: vaultURL)
        var logLines: [String] = []

        if !plan.parseFailures.isEmpty {
            logLines.append("解析失败（已跳过行）：")
            logLines.append(contentsOf: plan.parseFailures.map { $0.logLine })
        }

        var written: [String] = []
        var totalAdded = 0
        var skippedFileDuplicates = 0
        var movedMasteredVocab = 0
        var movedMasteredSentences = 0

        for (idx, day) in plan.days.enumerated() {
            progress?(Double(idx) / Double(max(plan.days.count, 1)), "写入 \(day.relativeOutputPath)…")

            do {
                let existing: String?
                if FileManager.default.fileExists(atPath: day.outputURL.path) {
                    existing = readTextFileLossy(day.outputURL)
                    if existing == nil {
                        logLines.append("无法读取现有 Markdown（\(day.relativeOutputPath)）：编码未知，已跳过写入以避免覆盖。")
                        continue
                    }
                } else {
                    existing = nil
                }
                let existingNormalized = existing?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

                if let existingNormalized {
                    let (sids, vids) = MarkdownUpdater.extractIDs(from: existingNormalized)
                    index.sentences.formUnion(sids)
                    index.vocab.formUnion(vids)
                }

                let update = MarkdownUpdater.update(
                    existing: existingNormalized,
                    date: day.date,
                    mode: plan.mode,
                    newSentences: day.newSentences,
                    newVocab: day.newVocab,
                    preferences: plan.preferences,
                    frontmatterSource: "imported"
                )

                skippedFileDuplicates += (day.newSentences.count - update.appendedSentences.count)
                skippedFileDuplicates += (day.newVocab.count - update.appendedVocab.count)

                let updatedNormalized = update.updatedMarkdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                let shouldWrite: Bool
                if let existingNormalized {
                    shouldWrite = updatedNormalized != existingNormalized
                } else {
                    // Only create a new file when we have new entries; avoid creating empty notes.
                    shouldWrite = !update.appendedSentences.isEmpty || !update.appendedVocab.isEmpty
                }
                guard shouldWrite else { continue }

                try AtomicFileWriter.writeString(update.updatedMarkdown, to: day.outputURL)
                written.append(day.relativeOutputPath)

                index.sentences.formUnion(update.appendedSentences.map { $0.id })
                index.vocab.formUnion(update.appendedVocab.map { $0.id })

                totalAdded += update.appendedSentences.count + update.appendedVocab.count
                movedMasteredVocab += update.movedMasteredVocabIDs.count
                movedMasteredSentences += update.movedMasteredSentenceIDs.count
            } catch {
                let msg = "写入失败（\(day.relativeOutputPath)）：\(error.localizedDescription)"
                logLines.append(msg)
            }
        }

        progress?(0.95, "保存索引…")
        try indexStore.save(index)

        if !logLines.isEmpty {
            try logger.appendSession(title: "Import", lines: logLines)
        }

        progress?(1.0, "完成")

        let totalSkipped = plan.skippedIndexDuplicates + plan.skippedBatchDuplicates + skippedFileDuplicates
        var summary = "导入摘要\n"
        summary += "- 新增：\(totalAdded)\n"
        summary += "- 跳过重复：\(totalSkipped)\n"
        summary += "- 解析失败：\(plan.parseFailures.count)\n"
        if movedMasteredVocab > 0 || movedMasteredSentences > 0 {
            summary += "- 归档已掌握：词汇 \(movedMasteredVocab) / 句子 \(movedMasteredSentences)\n"
        }
        summary += "- 写入文件（\(written.count)）：\n"
        for p in written {
            summary += "  - \(p)\n"
        }
        return summary
    }

    // MARK: - CSV Parsing

    private struct SentenceParseResult {
        let newItems: [SentenceClip]
        let failures: [ParseFailure]
        let skippedIndexDuplicates: Int
        let skippedBatchDuplicates: Int
        let yearCounts: [Int: Int]
    }

    private struct VocabParseResult {
        let newItems: [VocabClip]
        let failures: [ParseFailure]
        let skippedIndexDuplicates: Int
        let skippedBatchDuplicates: Int
    }

    private struct CSVPreview: Sendable {
        let delimiter: CSVDelimiter
        let header: [String]
        let sampleRows: [[String]]
    }

    struct ResolvedCSVImportConfig: Sendable {
        let delimiter: CSVDelimiter
        let headerSignature: String
        let fieldToHeaderIndex: [String: Int]
    }

    private static func headerSignature(from header: [String]) -> String {
        let normalized = header.map { HeaderNormalizer.normalize($0) }.joined(separator: "|")
        return sha1Hex(normalized)
    }

    private static func loadCSVPreview(url: URL) throws -> CSVPreview {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let prefix = data.prefix(65_536)
        let delimiter = CSVDelimiter.detect(fromPrefix: prefix)

        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
        var text: String? = nil
        for enc in encodings {
            if let s = String(data: prefix, encoding: enc) {
                text = s
                break
            }
        }
        guard let text else { throw CSVError.unreadableEncoding }

        // Parse just enough rows for header + a few samples.
        let rows = CSVParser.parse(text, delimiter: delimiter.byte, maxRows: 16, progress: nil)
        guard !rows.isEmpty else { throw CSVError.emptyFile }

        guard let headerIndex = rows.firstIndex(where: { row in
            !row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else {
            throw CSVError.emptyFile
        }

        let header = rows[headerIndex]
        let sample = Array(rows.dropFirst(headerIndex + 1).prefix(5))
        return CSVPreview(delimiter: delimiter, header: header, sampleRows: sample)
    }

    private static func resolveCSVImportConfig(url: URL, kind: ColumnMappingKind, required: Bool) throws -> ResolvedCSVImportConfig {
        _ = required // reserved for future behaviors (e.g. softer fallbacks)
        let preview = try loadCSVPreview(url: url)
        let signature = headerSignature(from: preview.header)

        let headerMap: [String: Int] = CSVTable(header: preview.header, rows: [], firstDataRowNumber: 2).headerIndexMap()

        let schema: ColumnSchema = (kind == .sentence) ? .sentence : .vocabulary

        // 1) Stored mapping (user-confirmed) has the highest priority.
        if let stored = ColumnMappingStore.load(kind: kind, headerSignature: signature) {
            var cleaned: [String: Int] = [:]
            cleaned.reserveCapacity(stored.fieldToHeaderIndex.count)
            for (k, idx) in stored.fieldToHeaderIndex {
                if idx >= 0 && idx < preview.header.count {
                    cleaned[k] = idx
                }
            }
            let missing = schema.requiredCanonicalNames.filter { cleaned[$0] == nil }
            if missing.isEmpty {
                return ResolvedCSVImportConfig(delimiter: preview.delimiter, headerSignature: signature, fieldToHeaderIndex: cleaned)
            }
        }

        // 2) Auto mapping by aliases.
        let auto = ColumnSchemaMatcher.autoMap(schema: schema, headerIndexMap: headerMap)
        if auto.missingRequired.isEmpty {
            return ResolvedCSVImportConfig(delimiter: preview.delimiter, headerSignature: signature, fieldToHeaderIndex: auto.fieldToHeaderIndex)
        }

        // 3) Still missing required fields -> ask user to map.
        throw ImportPlannerError.needsColumnMapping(
            PendingColumnMapping(
                fileURL: url,
                kind: kind,
                delimiter: preview.delimiter,
                header: preview.header,
                headerSignature: signature,
                suggestedFieldToHeaderIndex: auto.fieldToHeaderIndex,
                missingRequired: auto.missingRequired,
                sampleRows: preview.sampleRows
            )
        )
    }

    private static func parseSentenceCSV(
        url: URL,
        config: ResolvedCSVImportConfig,
        existingIndex: ImportedIndexStore.IndexSets,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> SentenceParseResult {
        let table = try CSVLoader.loadTable(from: url, delimiter: config.delimiter, progress: progress)

        guard let sentenceIdx = config.fieldToHeaderIndex["sentence"],
              let dateIdx = config.fieldToHeaderIndex["date"] else {
            throw NSError(domain: "OEI", code: 2, userInfo: [NSLocalizedDescriptionKey: "句子 CSV 缺少必需列：sentence/date"])
        }
        let translationIdx = config.fieldToHeaderIndex["translation"]
        let urlIdx = config.fieldToHeaderIndex["url"]

        var newItems: [SentenceClip] = []
        newItems.reserveCapacity(table.rows.count)

        var failures: [ParseFailure] = []
        var skipped = 0
        var skippedBatch = 0
        var yearCounts: [Int: Int] = [:]
        var seen: Set<String> = []

        func val(_ row: [String], _ idx: Int) -> String {
            idx < row.count ? row[idx] : ""
        }

        for (i, row) in table.rows.enumerated() {
            let lineNo = table.firstDataRowNumber + i
            if row.allSatisfy({ $0.oeiTrimmed().isEmpty }) {
                continue
            }

            let sentence = val(row, sentenceIdx).oeiTrimmed()
            if sentence.isEmpty {
                failures.append(ParseFailure(fileName: url.lastPathComponent, lineNumber: lineNo, reason: "句子为空"))
                continue
            }

            let translation = translationIdx.map { val(row, $0).oeiTrimmed() } ?? ""
            let rawURL = urlIdx.map { val(row, $0).oeiTrimmed() } ?? ""
            let urlField = rawURL.isEmpty ? nil : rawURL

            let rawDate = val(row, dateIdx).oeiTrimmed()
            guard let comps = DateParsing.parseSentenceDate(rawDate) else {
                failures.append(ParseFailure(fileName: url.lastPathComponent, lineNumber: lineNo, reason: "日期格式无法解析：\(rawDate)"))
                continue
            }

            yearCounts[comps.year, default: 0] += 1

            let date = DateParsing.formatYMD(year: comps.year, month: comps.month, day: comps.day)
            let id = SentenceClip.makeID(sentence: sentence, url: urlField)

            if seen.contains(id) {
                skippedBatch += 1
                continue
            }
            seen.insert(id)

            if existingIndex.sentences.contains(id) {
                skipped += 1
                continue
            }

            newItems.append(
                SentenceClip(
                    id: id,
                    sentence: sentence,
                    translation: translation,
                    url: urlField,
                    date: date
                )
            )
        }

        return SentenceParseResult(
            newItems: newItems,
            failures: failures,
            skippedIndexDuplicates: skipped,
            skippedBatchDuplicates: skippedBatch,
            yearCounts: yearCounts
        )
    }

    private static func parseVocabCSV(
        url: URL,
        config: ResolvedCSVImportConfig,
        fallbackYear: Int,
        existingIndex: ImportedIndexStore.IndexSets,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> VocabParseResult {
        let table = try CSVLoader.loadTable(from: url, delimiter: config.delimiter, progress: progress)

        guard let wordIdx = config.fieldToHeaderIndex["word"],
              let dateIdx = config.fieldToHeaderIndex["date"] else {
            throw NSError(domain: "OEI", code: 3, userInfo: [NSLocalizedDescriptionKey: "词汇 CSV 缺少必需列：word/date"])
        }
        let phoneticIdx = config.fieldToHeaderIndex["phonetic"]
        let translationIdx = config.fieldToHeaderIndex["translation"]

        var newItems: [VocabClip] = []
        newItems.reserveCapacity(table.rows.count)

        var failures: [ParseFailure] = []
        var skipped = 0
        var skippedBatch = 0
        var seen: Set<String> = []

        func val(_ row: [String], _ idx: Int) -> String {
            idx < row.count ? row[idx] : ""
        }

        for (i, row) in table.rows.enumerated() {
            let lineNo = table.firstDataRowNumber + i
            if row.allSatisfy({ $0.oeiTrimmed().isEmpty }) {
                continue
            }

            let word = val(row, wordIdx).oeiTrimmed()
            if word.isEmpty {
                failures.append(ParseFailure(fileName: url.lastPathComponent, lineNumber: lineNo, reason: "单词为空"))
                continue
            }

            let phoneticRaw = phoneticIdx.map { val(row, $0).oeiTrimmed() } ?? ""
            let phonetic = phoneticRaw.isEmpty ? nil : phoneticRaw

            let translation = translationIdx.map { val(row, $0).oeiTrimmed() } ?? ""
            let rawDate = val(row, dateIdx).oeiTrimmed()

            guard let comps = DateParsing.parseVocabularyDate(rawDate, fallbackYear: fallbackYear) else {
                failures.append(ParseFailure(fileName: url.lastPathComponent, lineNumber: lineNo, reason: "日期格式无法解析：\(rawDate)"))
                continue
            }

            let date = DateParsing.formatYMD(year: comps.year, month: comps.month, day: comps.day)
            let id = VocabClip.makeID(word: word)

            if seen.contains(id) {
                skippedBatch += 1
                continue
            }
            seen.insert(id)

            if existingIndex.vocab.contains(id) {
                skipped += 1
                continue
            }

            newItems.append(
                VocabClip(
                    id: id,
                    word: word,
                    phonetic: phonetic,
                    translation: translation,
                    source: nil,
                    date: date
                )
            )
        }

        return VocabParseResult(
            newItems: newItems,
            failures: failures,
            skippedIndexDuplicates: skipped,
            skippedBatchDuplicates: skippedBatch
        )
    }

    // MARK: - Output paths

    private static func outputFileURL(vaultURL: URL, prefs: PreferencesSnapshot, date: String) -> URL {
        let root = vaultURL.appendingPathComponent(prefs.outputRootRelativePath, isDirectory: true)
        if prefs.organizeByDateFolder {
            return root
                .appendingPathComponent(date, isDirectory: true)
                .appendingPathComponent("Review.md", isDirectory: false)
        }
        return root
            .appendingPathComponent("\(date).md", isDirectory: false)
    }

    private static func relativePath(from vault: URL, to file: URL) -> String {
        let vaultPath = vault.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(vaultPath + "/") {
            return String(filePath.dropFirst(vaultPath.count + 1))
        }
        return file.lastPathComponent
    }
}

private enum CSVKind {
    case sentence
    case vocabulary
    case unknown

    static func detect(url: URL) -> CSVKind {
        // First try: detect by header (delimiter-aware, alias-aware).
        if let (delimiter, header) = readHeaderPreview(url: url) {
            let map = CSVTable(header: header, rows: [], firstDataRowNumber: 2).headerIndexMap()

            let s = ColumnSchemaMatcher.autoMap(schema: .sentence, headerIndexMap: map)
            let v = ColumnSchemaMatcher.autoMap(schema: .vocabulary, headerIndexMap: map)

            let sOK = s.missingRequired.isEmpty
            let vOK = v.missingRequired.isEmpty

            if sOK && !vOK { return .sentence }
            if vOK && !sOK { return .vocabulary }

            if sOK && vOK {
                // Tie-break by "more matched fields", then filename heuristic.
                let sScore = s.fieldToHeaderIndex.count
                let vScore = v.fieldToHeaderIndex.count
                if sScore > vScore { return .sentence }
                if vScore > sScore { return .vocabulary }

                _ = delimiter // keep for future; detection already used delimiter.
            }
        }

        // Fallback: filename heuristic.
        let name = url.lastPathComponent.lowercased()
        if name.contains("sentence") { return .sentence }
        if name.contains("vocabulary") || name.contains("vocab") { return .vocabulary }
        return .unknown
    }

    private static func readHeaderPreview(url: URL) -> (CSVDelimiter, [String])? {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let prefix = data.prefix(65_536)
            let delimiter = CSVDelimiter.detect(fromPrefix: prefix)

            let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
            var text: String? = nil
            for enc in encodings {
                if let s = String(data: prefix, encoding: enc) {
                    text = s
                    break
                }
            }
            guard let text else { return nil }

            let rows = CSVParser.parse(text, delimiter: delimiter.byte, maxRows: 8, progress: nil)
            // Skip leading blank rows and return the first non-empty row as header.
            if let header = rows.first(where: { row in
                !row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }) {
                return (delimiter, header)
            }
            return nil
        } catch {
            return nil
        }
    }
}
