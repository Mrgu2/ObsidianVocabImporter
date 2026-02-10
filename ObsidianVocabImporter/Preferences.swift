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

        return PreferencesSnapshot(
            outputRootRelativePath: root.isEmpty ? Defaults.outputRootName : root,
            organizeByDateFolder: organize,
            yearCompletionStrategy: strategy,
            mergedLayoutStrategy: layout,
            highlightVocabInSentences: highlight,
            autoArchiveMastered: autoArchive,
            addMasteredTag: addTag,
            dictionaryLookupMode: dictMode
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
