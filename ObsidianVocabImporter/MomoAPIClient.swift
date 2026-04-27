import Foundation
import Security

struct MomoCloudSettings: Sendable, Equatable {
    let token: String
    let notepadTitle: String
    let selectedNotepadID: String?

    var trimmedToken: String { token.oeiTrimmed() }
    var trimmedNotepadTitle: String {
        let title = notepadTitle.oeiTrimmed()
        return title.isEmpty ? Defaults.momoCloudNotepadTitle : title
    }
    var trimmedSelectedNotepadID: String? {
        let id = selectedNotepadID?.oeiTrimmed() ?? ""
        return id.isEmpty ? nil : id
    }
    var createsNewNotepad: Bool { trimmedSelectedNotepadID == nil }

    var canUseAPI: Bool {
        !trimmedToken.isEmpty && (!createsNewNotepad || !trimmedNotepadTitle.isEmpty)
    }
}

enum MomoAPIError: Error, LocalizedError {
    case missingToken
    case invalidBaseURL
    case invalidResponseStatus(Int, String)
    case emptyResponse
    case notepadContentWouldBecomeEmpty
    case missingNotepadMetadata(String)
    case ambiguousNotepadTitle(String, [String])
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "墨墨开放 API Token 未配置。请先到 Settings -> 墨墨开放 API 填写 token。"
        case .invalidBaseURL:
            return "墨墨开放 API 地址无效。"
        case .invalidResponseStatus(let code, let detail):
            if detail.isEmpty {
                return "墨墨开放 API 请求失败（HTTP \(code)）。"
            }
            return "墨墨开放 API 请求失败（HTTP \(code)）：\(detail)"
        case .emptyResponse:
            return "墨墨开放 API 未返回内容。"
        case .notepadContentWouldBecomeEmpty:
            return "为避免覆盖远端词本为空内容，已取消同步。"
        case .missingNotepadMetadata(let field):
            return "远端云词本缺少必要字段 \(field)，为避免覆盖原 metadata，已取消同步。"
        case .ambiguousNotepadTitle(let title, let ids):
            let joined = ids.joined(separator: ", ")
            return "找到多个同名云词本“\(title)”（ID: \(joined)）。请先改成唯一标题，再同步。"
        case .apiError(let detail):
            return "墨墨开放 API 返回错误：\(detail)"
        }
    }
}

enum MomoAPIKeychain {
    private static let service = "com.wenjiegu.obsidian-vocab-importer.momo-open-api"
    private static let account = "token"

    static func loadToken() -> String {
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

    static func saveToken(_ value: String) throws {
        let trimmed = value.oeiTrimmed()
        if trimmed.isEmpty {
            try deleteToken()
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
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "无法保存墨墨 Token（status=\(addStatus)）。"])
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "无法保存墨墨 Token（status=\(updateStatus)）。"])
        }
    }

    static func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法删除墨墨 Token（status=\(status)）。"])
        }
    }
}

struct MomoBriefNotepad: Decodable, Sendable {
    let id: String
    let status: String
    let title: String
    let brief: String?
    let tags: [String]?
}

struct MomoNotepad: Decodable, Sendable {
    let id: String
    let status: String
    let content: String
    let title: String
    let brief: String?
    let tags: [String]?
}

struct MomoAPIClient: Sendable {
    private static let requestTimeout: TimeInterval = 60
    private static let maxRetryCount = 2
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) throws {
        guard let baseURL = URL(string: "https://open.maimemo.com/open") else {
            throw MomoAPIError.invalidBaseURL
        }
        let trimmed = token.oeiTrimmed()
        guard !trimmed.isEmpty else { throw MomoAPIError.missingToken }
        self.baseURL = baseURL
        self.token = trimmed
        self.session = session
    }

    func findNotepad(title: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> MomoBriefNotepad? {
        let normalizedTitle = title.oeiTrimmed()
        let limit = 10
        var offset = 0
        var page = 0
        var exactMatches: [MomoBriefNotepad] = []

        while page < 20 {
            progress?(min(0.2, Double(page) * 0.02))
            let batch = try await listNotepads(limit: limit, offset: offset)
            exactMatches.append(contentsOf: batch.filter { $0.title.oeiTrimmed() == normalizedTitle })
            if exactMatches.count > 1 {
                throw MomoAPIError.ambiguousNotepadTitle(normalizedTitle, exactMatches.map(\.id))
            }
            if batch.count < limit { return exactMatches.first }
            offset += limit
            page += 1
        }
        return exactMatches.first
    }

    func listAllNotepads(progress: (@Sendable (Double) -> Void)? = nil) async throws -> [MomoBriefNotepad] {
        let limit = 10
        var offset = 0
        var page = 0
        var all: [MomoBriefNotepad] = []

        while page < 100 {
            progress?(min(0.95, Double(page) * 0.05))
            let batch = try await listNotepads(limit: limit, offset: offset)
            all.append(contentsOf: batch)
            if batch.count < limit { break }
            offset += limit
            page += 1
        }

        progress?(1.0)
        return all
    }

    func getNotepad(id: String) async throws -> MomoNotepad {
        struct ResponseData: Decodable { let notepad: MomoNotepad }
        let request = try makeRequest(path: "/api/v1/notepads/\(id)", method: "GET")
        return try await send(request, as: ResponseData.self).notepad
    }

    func createNotepad(title: String, content: String, tags: [String] = ["Obsidian"]) async throws -> MomoBriefNotepad {
        guard !content.oeiTrimmed().isEmpty else { throw MomoAPIError.notepadContentWouldBecomeEmpty }
        struct Payload: Encodable { let notepad: NotepadPayload }
        struct ResponseData: Decodable { let notepad: MomoBriefNotepad }
        let payload = NotepadPayload(
            status: "PUBLISHED",
            content: normalizedNotepadContent(content),
            title: title,
            brief: "Synced from Obsidian Vocab Importer",
            tags: tags
        )
        var request = try makeRequest(path: "/api/v1/notepads", method: "POST")
        request.httpBody = try JSONEncoder().encode(Payload(notepad: payload))
        return try await send(request, as: ResponseData.self).notepad
    }

    func updateNotepad(_ notepad: MomoNotepad, content: String) async throws -> MomoBriefNotepad {
        guard !content.oeiTrimmed().isEmpty else { throw MomoAPIError.notepadContentWouldBecomeEmpty }
        guard let brief = notepad.brief else { throw MomoAPIError.missingNotepadMetadata("brief") }
        guard let tags = notepad.tags else { throw MomoAPIError.missingNotepadMetadata("tags") }
        struct Payload: Encodable { let notepad: NotepadPayload }
        struct ResponseData: Decodable { let notepad: MomoBriefNotepad }
        let payload = NotepadPayload(
            status: notepad.status,
            content: normalizedNotepadContent(content),
            title: notepad.title,
            brief: brief,
            tags: tags
        )
        var request = try makeRequest(path: "/api/v1/notepads/\(notepad.id)", method: "POST")
        request.httpBody = try JSONEncoder().encode(Payload(notepad: payload))
        return try await send(request, as: ResponseData.self).notepad
    }

    private func listNotepads(limit: Int, offset: Int) async throws -> [MomoBriefNotepad] {
        struct ResponseData: Decodable { let notepads: [MomoBriefNotepad] }
        var components = URLComponents(url: try url(for: "/api/v1/notepads"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        guard let url = components?.url else { throw MomoAPIError.invalidBaseURL }
        var request = URLRequest(url: url)
        configure(&request, method: "GET")
        return try await send(request, as: ResponseData.self).notepads
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let url = try url(for: path)
        var request = URLRequest(url: url)
        configure(&request, method: method)
        return request
    }

    private func url(for path: String) throws -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(normalizedPath, isDirectory: false)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.url != nil else {
            throw MomoAPIError.invalidBaseURL
        }
        return url
    }

    private func configure(_ request: inout URLRequest, method: String) {
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw MomoAPIError.emptyResponse }
                guard (200..<300).contains(http.statusCode) else {
                    let detail = String(data: data, encoding: .utf8)?.oeiTrimmed() ?? ""
                    if attempt < Self.maxRetryCount, Self.retryableStatusCodes.contains(http.statusCode) {
                        try await Task.sleep(nanoseconds: retryDelayNanoseconds(for: attempt, response: http))
                        attempt += 1
                        continue
                    }
                    throw MomoAPIError.invalidResponseStatus(http.statusCode, detail)
                }
                guard !data.isEmpty else { throw MomoAPIError.emptyResponse }
                let envelope = try JSONDecoder().decode(MomoEnvelope<T>.self, from: data)
                if !envelope.errors.isEmpty {
                    let detail = envelope.errors.map(\.displayText).joined(separator: " | ")
                    throw MomoAPIError.apiError(detail)
                }
                guard let payload = envelope.data else { throw MomoAPIError.emptyResponse }
                return payload
            } catch {
                guard attempt < Self.maxRetryCount, shouldRetry(after: error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: retryDelayNanoseconds(for: attempt, response: nil))
                attempt += 1
            }
        }
    }

    private func shouldRetry(after error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func retryDelayNanoseconds(for attempt: Int, response: HTTPURLResponse?) -> UInt64 {
        if let response, let retryAfter = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(retryAfter), seconds > 0 {
            return UInt64(seconds * 1_000_000_000)
        }

        let baseDelay = 0.75
        let delay = min(3.0, baseDelay * pow(2.0, Double(attempt)))
        return UInt64(delay * 1_000_000_000)
    }

    private struct NotepadPayload: Encodable {
        let status: String
        let content: String
        let title: String
        let brief: String
        let tags: [String]
    }

    private struct MomoEnvelope<T: Decodable>: Decodable {
        let errors: [MomoErrorItem]
        let data: T?
    }

    private struct MomoErrorItem: Decodable {
        let code: String?
        let msg: String?
        let info: String?

        var displayText: String {
            [code, msg, info]
                .compactMap { $0?.oeiTrimmed() }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }
}

func normalizedNotepadContent(_ content: String) -> String {
    let lines = content
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
    let trimmed = lines
        .map { $0.oeiTrimmed() }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    return trimmed.isEmpty ? "" : trimmed + "\n"
}

func mergeMomoNotepadContent(existingContent: String, newWords: [String]) -> (content: String, appendedWords: [String], skippedRemoteDuplicates: Int) {
    let existingLines = existingContent
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
        .map { $0.oeiTrimmed() }
        .filter { !$0.isEmpty }

    var seen = Set(existingLines.map { VocabClip.makeID(word: $0) })
    var merged = existingLines
    var appended: [String] = []
    var skippedRemote = 0

    for raw in newWords {
        let word = raw.oeiTrimmed()
        guard !word.isEmpty else { continue }
        let id = VocabClip.makeID(word: word)
        if seen.contains(id) {
            skippedRemote += 1
            continue
        }
        seen.insert(id)
        merged.append(word)
        appended.append(word)
    }

    return (
        content: normalizedNotepadContent(merged.joined(separator: "\n")),
        appendedWords: appended,
        skippedRemoteDuplicates: skippedRemote
    )
}
