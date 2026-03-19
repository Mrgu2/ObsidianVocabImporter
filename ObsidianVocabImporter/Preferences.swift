import Foundation

enum PreferencesKeys {
    static let outputRootName = "oei.outputRootName"
    static let organizeByDateFolder = "oei.organizeByDateFolder"
    static let yearCompletionStrategy = "oei.yearCompletionStrategy"

    // Merged mode layout / rendering behaviors
    static let mergedLayoutStrategy = "oei.mergedLayoutStrategy"
    static let highlightVocabInSentences = "oei.highlightVocabInSentences"
    static let autoArchiveMastered = "oei.autoArchiveMastered"
    static let addMasteredTag = "oei.addMasteredTag"

    // Quick capture: system dictionary lookup behavior
    static let dictionaryLookupMode = "oei.dictionaryLookupMode"

    // Smart lookup: provider + remote API config
    static let smartLookupProviderMode = "oei.smartLookupProviderMode"
    static let smartLookupBaseURL = "oei.smartLookupBaseURL"
    static let smartLookupAPIPath = "oei.smartLookupAPIPath"
    static let smartLookupModel = "oei.smartLookupModel"
    static let smartLookupExtraHeaders = "oei.smartLookupExtraHeaders"
    static let smartLookupUseCache = "oei.smartLookupUseCache"
    static let smartLookupEnrichImportVocab = "oei.smartLookupEnrichImportVocab"
}

enum RecentSelectionKeys {
    static let lastVaultPath = "oei.lastVaultPath"
    static let lastSentenceCSVPath = "oei.lastSentenceCSVPath"
    static let lastVocabCSVPath = "oei.lastVocabCSVPath"
    static let lastImportMode = "oei.lastImportMode"
}

enum Defaults {
    static let outputRootName = "English Clips"
    static let organizeByDateFolder = true
    static let yearCompletionStrategy: YearCompletionStrategy = .systemYear

    static let mergedLayoutStrategy: MergedLayoutStrategy = .vocabThenSentences
    static let highlightVocabInSentences = true
    static let autoArchiveMastered = true
    static let addMasteredTag = false

    // Prefer zh meaning, but allow English fallback when zh dictionary has no entry.
    static let dictionaryLookupMode: DictionaryLookupMode = .preferChineseThenEnglish

    static let smartLookupProviderMode: SmartLookupProviderMode = .localThenAPI
    static let smartLookupBaseURL = ""
    static let smartLookupAPIPath = "/v1/chat/completions"
    static let smartLookupModel = ""
    static let smartLookupExtraHeaders = ""
    static let smartLookupUseCache = true
    static let smartLookupEnrichImportVocab = false
}

enum DictionaryLookupMode: String, CaseIterable, Identifiable, Sendable {
    case preferChineseThenEnglish
    case preferChineseOnly
    case englishOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preferChineseThenEnglish: return "优先英汉（找不到则英语）"
        case .preferChineseOnly: return "仅英汉（找不到则空）"
        case .englishOnly: return "仅英语"
        }
    }
}

struct PreferencesSnapshot: Sendable, Equatable {
    let outputRootRelativePath: String
    let organizeByDateFolder: Bool
    let yearCompletionStrategy: YearCompletionStrategy
    let mergedLayoutStrategy: MergedLayoutStrategy
    let highlightVocabInSentences: Bool
    let autoArchiveMastered: Bool
    let addMasteredTag: Bool
    let dictionaryLookupMode: DictionaryLookupMode
    let smartLookupProviderMode: SmartLookupProviderMode
    let smartLookupBaseURL: String
    let smartLookupAPIPath: String
    let smartLookupModel: String
    let smartLookupExtraHeaders: String
    let smartLookupUseCache: Bool

    static func load(from defaults: UserDefaults = .standard) -> PreferencesSnapshot {
        let rawRoot = defaults.string(forKey: PreferencesKeys.outputRootName) ?? Defaults.outputRootName
        let root = sanitizeRootRelativePath(rawRoot)

        let organize = defaults.object(forKey: PreferencesKeys.organizeByDateFolder) as? Bool ?? Defaults.organizeByDateFolder

        let rawStrategy = defaults.string(forKey: PreferencesKeys.yearCompletionStrategy) ?? Defaults.yearCompletionStrategy.rawValue
        let strategy = YearCompletionStrategy(rawValue: rawStrategy) ?? Defaults.yearCompletionStrategy

        let rawLayout = defaults.string(forKey: PreferencesKeys.mergedLayoutStrategy) ?? Defaults.mergedLayoutStrategy.rawValue
        let layout = MergedLayoutStrategy(rawValue: rawLayout) ?? Defaults.mergedLayoutStrategy

        let highlight = defaults.object(forKey: PreferencesKeys.highlightVocabInSentences) as? Bool ?? Defaults.highlightVocabInSentences
        let autoArchive = defaults.object(forKey: PreferencesKeys.autoArchiveMastered) as? Bool ?? Defaults.autoArchiveMastered
        let addTag = defaults.object(forKey: PreferencesKeys.addMasteredTag) as? Bool ?? Defaults.addMasteredTag

        let rawDictMode = defaults.string(forKey: PreferencesKeys.dictionaryLookupMode) ?? Defaults.dictionaryLookupMode.rawValue
        let dictMode = DictionaryLookupMode(rawValue: rawDictMode) ?? Defaults.dictionaryLookupMode

        let rawSmartMode = defaults.string(forKey: PreferencesKeys.smartLookupProviderMode) ?? Defaults.smartLookupProviderMode.rawValue
        let smartMode = SmartLookupProviderMode(rawValue: rawSmartMode) ?? Defaults.smartLookupProviderMode
        let smartBaseURL = defaults.string(forKey: PreferencesKeys.smartLookupBaseURL) ?? Defaults.smartLookupBaseURL
        let smartAPIPath = defaults.string(forKey: PreferencesKeys.smartLookupAPIPath) ?? Defaults.smartLookupAPIPath
        let smartModel = defaults.string(forKey: PreferencesKeys.smartLookupModel) ?? Defaults.smartLookupModel
        let smartHeaders = defaults.string(forKey: PreferencesKeys.smartLookupExtraHeaders) ?? Defaults.smartLookupExtraHeaders
        let smartUseCache = defaults.object(forKey: PreferencesKeys.smartLookupUseCache) as? Bool ?? Defaults.smartLookupUseCache

        return PreferencesSnapshot(
            outputRootRelativePath: root.isEmpty ? Defaults.outputRootName : root,
            organizeByDateFolder: organize,
            yearCompletionStrategy: strategy,
            mergedLayoutStrategy: layout,
            highlightVocabInSentences: highlight,
            autoArchiveMastered: autoArchive,
            addMasteredTag: addTag,
            dictionaryLookupMode: dictMode,
            smartLookupProviderMode: smartMode,
            smartLookupBaseURL: smartBaseURL,
            smartLookupAPIPath: smartAPIPath,
            smartLookupModel: smartModel,
            smartLookupExtraHeaders: smartHeaders,
            smartLookupUseCache: smartUseCache
        )
    }

    var smartLookupSettings: SmartLookupSettings {
        SmartLookupSettings(
            providerMode: smartLookupProviderMode,
            baseURLString: smartLookupBaseURL,
            apiPathString: smartLookupAPIPath,
            model: smartLookupModel,
            apiKey: SmartLookupKeychain.loadAPIKey(),
            extraHeadersRaw: smartLookupExtraHeaders,
            useCache: smartLookupUseCache
        )
    }
}

private func sanitizeRootRelativePath(_ input: String) -> String {
    // Stored as relative path inside the Vault. This prevents accidental absolute paths or parent traversal.
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
    let comps = normalized
        .split(separator: "/")
        .map(String.init)
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

    return comps.joined(separator: "/")
}
