import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferencesKeys.outputRootName) private var outputRootName: String = Defaults.outputRootName
    @AppStorage(PreferencesKeys.organizeByDateFolder) private var organizeByDateFolder: Bool = Defaults.organizeByDateFolder
    @AppStorage(PreferencesKeys.yearCompletionStrategy) private var yearCompletionStrategyRaw: String = Defaults.yearCompletionStrategy.rawValue
    @AppStorage(PreferencesKeys.mergedLayoutStrategy) private var mergedLayoutStrategyRaw: String = Defaults.mergedLayoutStrategy.rawValue
    @AppStorage(PreferencesKeys.highlightVocabInSentences) private var highlightVocabInSentences: Bool = Defaults.highlightVocabInSentences
    @AppStorage(PreferencesKeys.autoArchiveMastered) private var autoArchiveMastered: Bool = Defaults.autoArchiveMastered
    @AppStorage(PreferencesKeys.addMasteredTag) private var addMasteredTag: Bool = Defaults.addMasteredTag
    @AppStorage(PreferencesKeys.dictionaryLookupMode) private var dictionaryLookupModeRaw: String = Defaults.dictionaryLookupMode.rawValue
    @AppStorage(PreferencesKeys.smartLookupProviderMode) private var smartLookupProviderModeRaw: String = Defaults.smartLookupProviderMode.rawValue
    @AppStorage(PreferencesKeys.smartLookupBaseURL) private var smartLookupBaseURL: String = Defaults.smartLookupBaseURL
    @AppStorage(PreferencesKeys.smartLookupAPIPath) private var smartLookupAPIPath: String = Defaults.smartLookupAPIPath
    @AppStorage(PreferencesKeys.smartLookupModel) private var smartLookupModel: String = Defaults.smartLookupModel
    @AppStorage(PreferencesKeys.smartLookupExtraHeaders) private var smartLookupExtraHeaders: String = Defaults.smartLookupExtraHeaders
    @AppStorage(PreferencesKeys.smartLookupUseCache) private var smartLookupUseCache: Bool = Defaults.smartLookupUseCache
    @AppStorage(PreferencesKeys.momoCloudNotepadTitle) private var momoCloudNotepadTitle: String = Defaults.momoCloudNotepadTitle

    @State private var launchAtLoginEnabled: Bool = false
    @State private var launchAtLoginApprovalRequired: Bool = false
    @State private var launchAtLoginErrorMessage: String = ""
    @State private var isShowingLaunchAtLoginError: Bool = false
    @State private var smartLookupAPIKey: String = ""
    @State private var smartLookupMessage: String = ""
    @State private var smartLookupPreset: SmartLookupProviderPreset = .custom
    @State private var momoCloudToken: String = ""
    @State private var momoCloudMessage: String = ""
    @State private var isTestingMomoCloudConnection: Bool = false

    private var yearStrategyBinding: Binding<YearCompletionStrategy> {
        Binding(
            get: { YearCompletionStrategy(rawValue: yearCompletionStrategyRaw) ?? Defaults.yearCompletionStrategy },
            set: { yearCompletionStrategyRaw = $0.rawValue }
        )
    }

    private var mergedLayoutBinding: Binding<MergedLayoutStrategy> {
        Binding(
            get: { MergedLayoutStrategy(rawValue: mergedLayoutStrategyRaw) ?? Defaults.mergedLayoutStrategy },
            set: { mergedLayoutStrategyRaw = $0.rawValue }
        )
    }

    private var dictionaryLookupModeBinding: Binding<DictionaryLookupMode> {
        Binding(
            get: { DictionaryLookupMode(rawValue: dictionaryLookupModeRaw) ?? Defaults.dictionaryLookupMode },
            set: { dictionaryLookupModeRaw = $0.rawValue }
        )
    }

    private var smartLookupProviderModeBinding: Binding<SmartLookupProviderMode> {
        Binding(
            get: { SmartLookupProviderMode(rawValue: smartLookupProviderModeRaw) ?? Defaults.smartLookupProviderMode },
            set: { smartLookupProviderModeRaw = $0.rawValue }
        )
    }

    private func syncLaunchAtLoginState() {
        let st = LaunchAtLoginManager.status()
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabledOrPendingApproval(st)
        launchAtLoginApprovalRequired = (st == .requiresApproval)
    }

    private func applySmartLookupPreset(_ preset: SmartLookupProviderPreset) {
        guard preset != .custom else { return }
        smartLookupBaseURL = preset.suggestedBaseURL
        smartLookupAPIPath = preset.suggestedAPIPath
        if smartLookupModel.oeiTrimmed().isEmpty || smartLookupPreset != preset {
            smartLookupModel = preset.suggestedModel
        }
        smartLookupMessage = "已填充 \(preset.displayName) 默认配置。"
    }

    private func testMomoCloudConnection() {
        momoCloudMessage = ""
        let settings = MomoCloudSettings(token: momoCloudToken, notepadTitle: momoCloudNotepadTitle, selectedNotepadID: nil)
        guard settings.canUseAPI else {
            momoCloudMessage = "请先填写墨墨开放 API Token。"
            return
        }

        isTestingMomoCloudConnection = true
        Task {
            do {
                let client = try MomoAPIClient(token: settings.trimmedToken)
                let notepads = try await client.listAllNotepads()
                await MainActor.run {
                    momoCloudMessage = "连接成功：鉴权和云词本列表读取正常，共拉取 \(notepads.count) 本。导入页可直接选择具体词本；只有选择“新建云词本”时，才会使用这里的标题“\(settings.trimmedNotepadTitle)”。"
                    isTestingMomoCloudConnection = false
                }
            } catch {
                await MainActor.run {
                    momoCloudMessage = "连接测试失败：\(error.localizedDescription)"
                    isTestingMomoCloudConnection = false
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("应用") {
                Toggle("开机自启动", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        let oldEnabled = launchAtLoginEnabled
                        let oldApproval = launchAtLoginApprovalRequired
                        launchAtLoginEnabled = newValue
                        do {
                            try LaunchAtLoginManager.setEnabled(newValue)
                            syncLaunchAtLoginState()

                            if launchAtLoginApprovalRequired {
                                // Some environments need explicit approval in System Settings.
                                LaunchAtLoginManager.openSystemSettingsLoginItems()
                            }
                        } catch {
                            launchAtLoginEnabled = oldEnabled
                            launchAtLoginApprovalRequired = oldApproval
                            launchAtLoginErrorMessage = error.localizedDescription
                            isShowingLaunchAtLoginError = true
                        }
                    }
                ))

                if launchAtLoginApprovalRequired {
                    Button("打开系统设置（登录项）") {
                        LaunchAtLoginManager.openSystemSettingsLoginItems()
                    }
                    Text("系统需要你在“系统设置 > 通用 > 登录项”里允许该登录项，才能真正生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("说明：开启后应用会加入系统“登录项”，以便开机登录后自动启动。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("输出") {
                TextField("Vault 内输出根目录名", text: $outputRootName)
                Toggle("按日期建立文件夹", isOn: $organizeByDateFolder)
                Text("默认输出：English Clips/YYYY-MM-DD/Review.md（关闭后为 English Clips/YYYY-MM-DD.md）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("全部合并（布局与复习）") {
                Picker("合并策略", selection: mergedLayoutBinding) {
                    ForEach(MergedLayoutStrategy.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }

                Toggle("句子内高亮当天词汇（加粗）", isOn: $highlightVocabInSentences)

                Toggle("勾选后自动归档到 Mastered 分区", isOn: $autoArchiveMastered)

                Toggle("归档条目加标签 #mastered", isOn: $addMasteredTag)
                    .disabled(!autoArchiveMastered)

                Text("说明：\n- 先词后句：保持 Vocabulary 在前、Sentences 在后。\n- 按时间线交错：在同一分区交错排列词汇与句子（无真实时间戳时为“尽量交错”）。\n- 以句子为主：Sentences 在前，并在句子条目下展示相关词汇。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("快速捕获（查词）") {
                Picker("词典", selection: dictionaryLookupModeBinding) {
                    ForEach(DictionaryLookupMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                Text("说明：当英汉词典查不到时，可以回退到英语词典，至少保证有释义。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("智能查词（API）") {
                HStack(spacing: 12) {
                    Picker("预设", selection: $smartLookupPreset) {
                        ForEach(SmartLookupProviderPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .frame(width: 180)

                    Button("填充预设") {
                        applySmartLookupPreset(smartLookupPreset)
                    }
                    .disabled(smartLookupPreset == .custom)
                }

                Picker("Provider", selection: smartLookupProviderModeBinding) {
                    ForEach(SmartLookupProviderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                TextField("Base URL", text: $smartLookupBaseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("API Path", text: $smartLookupAPIPath)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $smartLookupModel)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key（保存在 Keychain）", text: $smartLookupAPIKey)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra Headers（可选，每行 `Header: Value`）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $smartLookupExtraHeaders)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72, maxHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                }

                Toggle("启用本地缓存", isOn: $smartLookupUseCache)

                HStack(spacing: 10) {
                    Button("清空智能查词缓存") {
                        smartLookupMessage = ""
                        Task {
                            do {
                                try await SmartLookupService.shared.clearCache()
                                await MainActor.run {
                                    smartLookupMessage = "已清空智能查词缓存。"
                                }
                            } catch {
                                await MainActor.run {
                                    smartLookupMessage = "清空缓存失败：\(error.localizedDescription)"
                                }
                            }
                        }
                    }

                    if !smartLookupMessage.isEmpty {
                        Text(smartLookupMessage)
                            .font(.footnote)
                            .foregroundStyle(smartLookupMessage.contains("失败") ? .red : .secondary)
                    }
                }

                Text("说明：\n- system prompt 固定写死，不提供自定义入口。\n- Base URL 和 API Path 分开配置，避免不同 provider 的兼容路径不一致。\n- MiniMax / NVIDIA 预设会先填一套常见默认值，你仍可手动改。\n- API Key 只保存在当前 Mac 的 Keychain，不会写入 Vault。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("墨墨开放 API") {
                TextField("目标云词本标题", text: $momoCloudNotepadTitle)
                    .textFieldStyle(.roundedBorder)

                SecureField("墨墨开放 API Token（保存在 Keychain）", text: $momoCloudToken)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("测试连接") {
                        testMomoCloudConnection()
                    }
                    .disabled(isTestingMomoCloudConnection || momoCloudToken.oeiTrimmed().isEmpty)

                    if isTestingMomoCloudConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !momoCloudMessage.isEmpty {
                    Text(momoCloudMessage)
                        .font(.footnote)
                        .foregroundStyle(momoCloudMessage.contains("失败") ? .red : .secondary)
                }

                Text("说明：\n- Token 需要先在墨墨背单词 app 里申请。\n- 主界面会先拉取云词本列表并让你选择具体词本，不再按标题匹配已有词本。\n- 这里的“目标云词本标题”只在主界面选择“新建云词本”时用于创建新词本。\n- 同步只会创建或追加更新目标云词本，不会删除远端词本内容。\n- Token 只保存在当前 Mac 的 Keychain，不会写入 Vault。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("词汇年份补全") {
                Picker("策略", selection: yearStrategyBinding) {
                    ForEach(YearCompletionStrategy.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }

                Text("当词汇 CSV 的 Date 只有月日（MM-DD）时，应用需要补全年份才能统一输出为 yyyy-MM-dd。\n\n- 使用当前系统年份：始终使用 Calendar.current 的年份。\n- 使用句子 CSV 中出现最多的年份：如果同时选择了句子 CSV 且能解析到年份集合，则使用出现次数最多的年份；否则回退到系统年份。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            // Always reflect the effective system login item state.
            syncLaunchAtLoginState()
            smartLookupAPIKey = SmartLookupKeychain.loadAPIKey()
            smartLookupPreset = .custom
            momoCloudToken = MomoAPIKeychain.loadToken()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User may approve/deny in System Settings; refresh when coming back.
            syncLaunchAtLoginState()
        }
        .onChange(of: smartLookupAPIKey) { newValue in
            do {
                try SmartLookupKeychain.saveAPIKey(newValue)
                smartLookupMessage = ""
            } catch {
                smartLookupMessage = "保存 API Key 失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: momoCloudToken) { newValue in
            do {
                try MomoAPIKeychain.saveToken(newValue)
                momoCloudMessage = ""
            } catch {
                momoCloudMessage = "保存墨墨 Token 失败：\(error.localizedDescription)"
            }
        }
        .alert("无法设置开机自启动", isPresented: $isShowingLaunchAtLoginError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(launchAtLoginErrorMessage)
        }
    }
}

private enum LaunchAtLoginManager {
    static func status() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func isEnabledOrPendingApproval(_ st: SMAppService.Status) -> Bool {
        switch st {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
