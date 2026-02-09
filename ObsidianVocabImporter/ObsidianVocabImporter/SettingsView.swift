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

    @State private var launchAtLoginEnabled: Bool = false
    @State private var launchAtLoginApprovalRequired: Bool = false
    @State private var launchAtLoginErrorMessage: String = ""
    @State private var isShowingLaunchAtLoginError: Bool = false

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

    private func syncLaunchAtLoginState() {
        let st = LaunchAtLoginManager.status()
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabledOrPendingApproval(st)
        launchAtLoginApprovalRequired = (st == .requiresApproval)
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
        .frame(width: 520)
        .onAppear {
            // Always reflect the effective system login item state.
            syncLaunchAtLoginState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User may approve/deny in System Settings; refresh when coming back.
            syncLaunchAtLoginState()
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
