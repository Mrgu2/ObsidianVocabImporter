import Foundation
import Security

enum SmartLookupProviderMode: String, CaseIterable, Identifiable, Sendable {
    case localOnly
    case localThenAPI
    case apiOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localOnly: return "仅本地词典"
        case .localThenAPI: return "本地优先，必要时 API"
        case .apiOnly: return "仅 API"
        }
    }
}

enum SmartLookupIntent: Sendable {
    case automaticFill
    case explicitEnhancement
}

struct SmartLookupSettings: Sendable, Equatable {
    let providerMode: SmartLookupProviderMode
    let baseURLString: String
    let apiPathString: String
    let model: String
    let apiKey: String
    let extraHeadersRaw: String
    let useCache: Bool

    var trimmedBaseURL: String { baseURLString.oeiTrimmed() }
    var trimmedAPIPath: String { apiPathString.oeiTrimmed() }
    var trimmedModel: String { model.oeiTrimmed() }
    var trimmedAPIKey: String { apiKey.oeiTrimmed() }
    var canUseAPI: Bool {
        !trimmedBaseURL.isEmpty && !trimmedModel.isEmpty && !trimmedAPIKey.isEmpty
    }

    func parsedExtraHeaders() -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in extraHeadersRaw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = rawLine.oeiTrimmed()
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).oeiTrimmed()
            let value = String(line[line.index(after: colon)...]).oeiTrimmed()
            guard !key.isEmpty, !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}

enum SmartLookupProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case custom
    case minimax
    case nvidia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: return "自定义"
        case .minimax: return "MiniMax"
        case .nvidia: return "NVIDIA"
        }
    }

    var suggestedBaseURL: String {
        switch self {
        case .custom: return ""
        case .minimax: return "https://api.minimax.io"
        case .nvidia: return "https://integrate.api.nvidia.com"
        }
    }

    var suggestedAPIPath: String {
        switch self {
        case .custom: return "/v1/chat/completions"
        case .minimax: return "/v1/chat/completions"
        case .nvidia: return "/v1/chat/completions"
        }
    }

    var suggestedModel: String {
        switch self {
        case .custom: return ""
        case .minimax: return "MiniMax-M2.5"
        case .nvidia: return "meta/llama-3.3-70b-instruct"
        }
    }
}

enum SmartLookupError: Error, LocalizedError {
    case invalidTerm
    case missingAPIConfiguration
    case invalidBaseURL
    case invalidResponseStatus(Int, String)
    case emptyResponse
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidTerm:
            return "要查询的词条无效。"
        case .missingAPIConfiguration:
            return "智能查词尚未配置完整的 API（需要 Base URL、Model、API Key）。"
        case .invalidBaseURL:
            return "智能查词的 Base URL 无效。"
        case .invalidResponseStatus(let code, let detail):
            if detail.isEmpty {
                return "智能查词请求失败（HTTP \(code)）。"
            }
            return "智能查词请求失败（HTTP \(code)）：\(detail)"
        case .emptyResponse:
            return "智能查词未返回内容。"
        case .invalidJSON:
            return "智能查词返回了非预期 JSON。"
        }
    }
}

enum SmartLookupKeychain {
    private static let service = "com.wenjiegu.obsidian-vocab-importer.smart-lookup"
    private static let account = "api-key"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func saveAPIKey(_ value: String) throws {
        let trimmed = value.oeiTrimmed()
        if trimmed.isEmpty {
            try deleteAPIKey()
            return
        }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "无法保存 API Key（status=\(addStatus)）。"])
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "无法保存 API Key（status=\(updateStatus)）。"])
        }
    }

    static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法删除 API Key（status=\(status)）。"])
        }
    }
}

private struct SmartLookupCacheEntry: Codable, Sendable {
    let result: SmartLookupResult
    let savedAt: Date
}

private struct SmartLookupCacheFile: Codable, Sendable {
    var entries: [String: SmartLookupCacheEntry]
}

private actor SmartLookupCacheStore {
    private let fileURL: URL
    private var loaded = false
    private var entries: [String: SmartLookupCacheEntry] = [:]

    init() {
        let fm = FileManager.default
        let supportDir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = supportDir.appendingPathComponent("ObsidianVocabImporter", isDirectory: true)
        fileURL = dir.appendingPathComponent("smart_lookup_cache.json", isDirectory: false)
    }

    func result(for key: String) throws -> SmartLookupResult? {
        try ensureLoaded()
        return entries[key]?.result
    }

    func save(_ result: SmartLookupResult, for key: String) throws {
        try ensureLoaded()
        entries[key] = SmartLookupCacheEntry(result: result, savedAt: Date())
        try persist()
    }

    func clear() throws {
        entries = [:]
        loaded = true
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let decoded = try JSONDecoder().decode(SmartLookupCacheFile.self, from: data)
        entries = decoded.entries
    }

    private func persist() throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = SmartLookupCacheFile(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try AtomicFileWriter.write(data, to: fileURL)
    }
}

private struct SmartLookupOpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let response_format: ResponseFormat
}

private struct SmartLookupOpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: FlexibleMessageContent?
        }

        let message: Message
    }

    let choices: [Choice]
}

private enum FlexibleMessageContent: Decodable {
    case text(String)
    case parts([Part])

    struct Part: Decodable {
        let type: String?
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        if let parts = try? container.decode([Part].self) {
            self = .parts(parts)
            return
        }
        throw DecodingError.typeMismatch(FlexibleMessageContent.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported content shape"))
    }

    var textValue: String? {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            let joined = parts.compactMap { $0.text?.oeiTrimmed() }.filter { !$0.isEmpty }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
    }
}

private enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(_ raw: Any) {
        switch raw {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init))
        case let value as [Any]:
            self = .array(value.map(JSONValue.init))
        default:
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

actor SmartLookupService {
    static let shared = SmartLookupService()

    private let cacheStore = SmartLookupCacheStore()
    private let session: URLSession
    private var inFlight: [String: Task<SmartLookupResult, Error>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: config)
        }
    }

    static func sanitizeLookupTerm(_ raw: String) -> String {
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

    func localMeaning(for term: String, mode: DictionaryLookupMode) -> String? {
        SystemDictionaryLookup.lookupMeaningSingleLine(term: term, mode: mode)
    }

    func clearCache() async throws {
        try await cacheStore.clear()
    }

    func lookupVocabulary(
        term rawTerm: String,
        existingTranslation rawExistingTranslation: String,
        settings: SmartLookupSettings,
        dictionaryMode: DictionaryLookupMode,
        intent: SmartLookupIntent
    ) async throws -> SmartLookupResult? {
        let term = Self.sanitizeLookupTerm(rawTerm)
        guard !term.isEmpty else { throw SmartLookupError.invalidTerm }

        let existingTranslation = rawExistingTranslation.oeiTrimmed()
        let localMeaning: String?
        switch settings.providerMode {
        case .localOnly, .localThenAPI:
            localMeaning = self.localMeaning(for: term, mode: dictionaryMode)
        case .apiOnly:
            localMeaning = nil
        }

        let shouldUseAPI: Bool
        switch settings.providerMode {
        case .localOnly:
            shouldUseAPI = false
        case .apiOnly:
            shouldUseAPI = true
        case .localThenAPI:
            switch intent {
            case .automaticFill:
                shouldUseAPI = (localMeaning?.oeiTrimmed().isEmpty ?? true) && existingTranslation.isEmpty
            case .explicitEnhancement:
                shouldUseAPI = true
            }
        }

        if !shouldUseAPI {
            return makeMergedResult(term: term, localMeaning: localMeaning, existingTranslation: existingTranslation, remoteResult: nil)
        }

        guard settings.canUseAPI else {
            switch settings.providerMode {
            case .apiOnly:
                throw SmartLookupError.missingAPIConfiguration
            case .localOnly, .localThenAPI:
                return makeMergedResult(term: term, localMeaning: localMeaning, existingTranslation: existingTranslation, remoteResult: nil)
            }
        }

        let cacheKey = cacheKeyForRequest(term: term, settings: settings)
        if settings.useCache, let cached = try await cacheStore.result(for: cacheKey) {
            return makeMergedResult(term: term, localMeaning: localMeaning, existingTranslation: existingTranslation, remoteResult: cached)
        }

        if let running = inFlight[cacheKey] {
            let remote = try await running.value
            return makeMergedResult(term: term, localMeaning: localMeaning, existingTranslation: existingTranslation, remoteResult: remote)
        }

        let task = Task<SmartLookupResult, Error> {
            let remote = try await requestRemoteResult(term: term, existingTranslation: existingTranslation, localMeaning: localMeaning, settings: settings)
            if settings.useCache {
                try await cacheStore.save(remote, for: cacheKey)
            }
            return remote
        }
        inFlight[cacheKey] = task
        defer { inFlight.removeValue(forKey: cacheKey) }

        let remote = try await task.value
        return makeMergedResult(term: term, localMeaning: localMeaning, existingTranslation: existingTranslation, remoteResult: remote)
    }

    private func makeMergedResult(
        term: String,
        localMeaning: String?,
        existingTranslation: String,
        remoteResult: SmartLookupResult?
    ) -> SmartLookupResult? {
        let preferredMeaning = [
            remoteResult?.meaningZH.oeiTrimmed(),
            existingTranslation,
            localMeaning?.oeiTrimmed(),
            remoteResult?.meaningEN?.oeiTrimmed()
        ].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""

        let remoteExamples = Array((remoteResult?.examples ?? []).prefix(2))
        let meaningEN = remoteResult?.meaningEN?.oeiTrimmed()
        let usageNote = remoteResult?.usageNote?.oeiTrimmed()

        guard !preferredMeaning.isEmpty || !remoteExamples.isEmpty else { return nil }
        return SmartLookupResult(
            term: term,
            meaningZH: preferredMeaning,
            meaningEN: (meaningEN?.isEmpty == false ? meaningEN : nil),
            examples: remoteExamples,
            usageNote: (usageNote?.isEmpty == false ? usageNote : nil)
        )
    }

    private func requestRemoteResult(
        term: String,
        existingTranslation: String,
        localMeaning: String?,
        settings: SmartLookupSettings
    ) async throws -> SmartLookupResult {
        let endpoint = try endpointURL(from: settings.trimmedBaseURL, apiPath: settings.trimmedAPIPath)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        for (header, value) in settings.parsedExtraHeaders() {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let body = SmartLookupOpenAIRequest(
            model: settings.trimmedModel,
            messages: [
                .init(role: "system", content: Self.fixedSystemPrompt),
                .init(role: "user", content: makeUserPrompt(term: term, existingTranslation: existingTranslation, localMeaning: localMeaning))
            ],
            temperature: 0.2,
            response_format: .init(type: "json_object")
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SmartLookupError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.oeiTrimmed() ?? ""
            throw SmartLookupError.invalidResponseStatus(http.statusCode, detail)
        }

        let decoded = try JSONDecoder().decode(SmartLookupOpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.textValue?.oeiTrimmed(), !content.isEmpty else {
            throw SmartLookupError.emptyResponse
        }

        guard let parsed = Self.parseResultFromModelContent(content, fallbackTerm: term) else {
            throw SmartLookupError.invalidJSON
        }
        return parsed
    }

    private func endpointURL(from baseURLString: String, apiPath: String) throws -> URL {
        guard let base = URL(string: baseURLString), var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw SmartLookupError.invalidBaseURL
        }

        let trimmedPath = apiPath.isEmpty ? "/v1/chat/completions" : apiPath
        let normalizedPath: String
        if trimmedPath.hasPrefix("/") {
            normalizedPath = trimmedPath
        } else {
            normalizedPath = "/" + trimmedPath
        }

        let basePath = comps.path == "/" ? "" : comps.path
        comps.path = normalizedPath.hasPrefix(basePath) ? normalizedPath : basePath + normalizedPath
        guard let url = comps.url else {
            throw SmartLookupError.invalidBaseURL
        }
        return url
    }

    private func cacheKeyForRequest(term: String, settings: SmartLookupSettings) -> String {
        let raw = [
            term.lowercased(),
            settings.providerMode.rawValue,
            settings.trimmedBaseURL.lowercased(),
            settings.trimmedAPIPath.lowercased(),
            settings.trimmedModel,
            Self.fixedPromptVersion,
            Self.schemaVersion
        ].joined(separator: "|")
        return sha1Hex(raw)
    }

    private func makeUserPrompt(term: String, existingTranslation: String, localMeaning: String?) -> String {
        var lines: [String] = []
        lines.append("term: \(term)")
        if !existingTranslation.isEmpty {
            lines.append("existing_translation: \(existingTranslation)")
        }
        if let localMeaning, !localMeaning.oeiTrimmed().isEmpty {
            lines.append("local_dictionary_hint: \(localMeaning)")
        }
        lines.append("need_examples: true")
        lines.append("example_limit: 2")
        return lines.joined(separator: "\n")
    }

    private func stripCodeFencesIfNeeded(_ text: String) -> String {
        let trimmed = text.oeiTrimmed()
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return trimmed }
        return lines.dropFirst().dropLast().joined(separator: "\n").oeiTrimmed()
    }

    static func parseResultFromModelContent(_ content: String, fallbackTerm: String) -> SmartLookupResult? {
        let normalized = stripCodeFencesIfNeededStatic(content)
        guard let jsonText = extractFirstJSONObject(from: normalized),
              let data = jsonText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let root = JSONValue(raw).objectValue else {
            return nil
        }

        let dict = pickBestPayloadDictionary(root) ?? root

        let term = firstString(in: dict, keys: ["term", "word", "query"])?.oeiTrimmed() ?? fallbackTerm
        let meaningZH = firstString(in: dict, keys: ["meaning_zh", "meaningZh", "translation", "chinese", "definition_zh", "definitionZh", "definition", "gloss"])?.oeiTrimmed() ?? ""
        let meaningEN = firstString(in: dict, keys: ["meaning_en_optional", "meaning_en", "meaningEnOptional", "meaningEn", "english", "definition_en", "definitionEn"])?.oeiTrimmed()
        let usageNote = firstString(in: dict, keys: ["usage_note_optional", "usage_note", "usageNoteOptional", "usageNote", "usage", "note"])?.oeiTrimmed()
        let examples = parseExamples(from: dict)

        guard !meaningZH.isEmpty || !(meaningEN ?? "").isEmpty || !examples.isEmpty else {
            return nil
        }

        return SmartLookupResult(
            term: term,
            meaningZH: meaningZH,
            meaningEN: (meaningEN?.isEmpty == false ? meaningEN : nil),
            examples: Array(examples.prefix(2)),
            usageNote: (usageNote?.isEmpty == false ? usageNote : nil)
        )
    }

    private static func stripCodeFencesIfNeededStatic(_ text: String) -> String {
        let trimmed = text.oeiTrimmed()
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return trimmed }
        return lines.dropFirst().dropLast().joined(separator: "\n").oeiTrimmed()
    }

    private static func extractFirstJSONObject(from text: String) -> String? {
        let chars = Array(text)
        var depth = 0
        var start: Int?
        var inString = false
        var isEscaping = false

        for (idx, ch) in chars.enumerated() {
            if inString {
                if isEscaping {
                    isEscaping = false
                } else if ch == "\\" {
                    isEscaping = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
                continue
            }

            if ch == "{" {
                if depth == 0 {
                    start = idx
                }
                depth += 1
            } else if ch == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start {
                    return String(chars[start...idx])
                }
            }
        }
        return nil
    }

    private static func pickBestPayloadDictionary(_ root: [String: JSONValue]) -> [String: JSONValue]? {
        let directKeys = Set(root.keys)
        let targetKeys: Set<String> = ["meaning_zh", "meaningZh", "translation", "examples", "example", "term", "word"]
        if !directKeys.isDisjoint(with: targetKeys) {
            return root
        }

        for key in ["data", "result", "output", "answer", "content"] {
            if let nested = root[key]?.objectValue {
                let nestedKeys = Set(nested.keys)
                if !nestedKeys.isDisjoint(with: targetKeys) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func firstString(in dict: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key]?.stringValue?.oeiTrimmed(), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseExamples(from dict: [String: JSONValue]) -> [VocabExample] {
        let candidates = [
            dict["examples"],
            dict["example"],
            dict["example_sentences"],
            dict["exampleSentences"],
            dict["sentences"]
        ]

        for candidate in candidates {
            if let array = candidate?.arrayValue {
                let parsed = array.compactMap(parseExample)
                if !parsed.isEmpty { return parsed }
            }
            if let object = candidate?.objectValue, let parsed = parseExample(.object(object)) {
                return [parsed]
            }
            if let string = candidate?.stringValue?.oeiTrimmed(), !string.isEmpty {
                return [VocabExample(en: string, zh: nil)]
            }
        }
        return []
    }

    private static func parseExample(_ value: JSONValue) -> VocabExample? {
        switch value {
        case .string(let text):
            let clean = text.oeiTrimmed().oeiCompressWhitespaceToSingleSpaces()
            return clean.isEmpty ? nil : VocabExample(en: clean, zh: nil)
        case .object(let dict):
            let english = firstString(in: dict, keys: ["en", "english", "text", "sentence", "example"])?.oeiCompressWhitespaceToSingleSpaces()
            let chinese = firstString(in: dict, keys: ["zh_optional", "zh", "chinese", "translation", "meaning"])?.oeiCompressWhitespaceToSingleSpaces()
            guard let english, !english.isEmpty else { return nil }
            return VocabExample(en: english, zh: (chinese?.isEmpty == false ? chinese : nil))
        default:
            return nil
        }
    }

    private static let fixedPromptVersion = "smart-lookup-v1"
    private static let schemaVersion = "schema-v1"
    private static let fixedSystemPrompt = """
你是一个英语学习词卡助手。你只输出严格 JSON，不要输出 markdown、解释、前后缀、代码块。
目标：为用户提供适合复习的简短中文释义，以及 1 到 2 条自然、常用、简短的英文例句。
要求：
1. 返回 JSON 对象，字段固定为：term, meaning_zh, meaning_en_optional, examples, usage_note_optional。
2. examples 是数组，每项字段固定为 en, zh_optional。
3. meaning_zh 尽量简短，优先高频核心义，不要长段落。
4. 例句必须自然、简洁、常用，避免书面腔和生僻表达。
5. 不要编造词源、近义词、派生词、频率信息。
6. 如果中文释义不确定，meaning_zh 留空字符串，但仍尽量给英文义项或例句。
7. 不要返回 null；缺失字段用空字符串或空数组。
"""
}
