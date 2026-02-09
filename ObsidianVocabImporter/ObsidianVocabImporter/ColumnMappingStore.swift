import Foundation

struct ColumnMapping: Codable, Sendable {
    let kind: ColumnMappingKind
    let headerSignature: String
    let fieldToHeaderIndex: [String: Int]
}

struct PendingColumnMapping: Identifiable, Sendable {
    let id = UUID()

    let fileURL: URL
    let kind: ColumnMappingKind
    let delimiter: CSVDelimiter
    let header: [String]
    let headerSignature: String
    let suggestedFieldToHeaderIndex: [String: Int]
    let missingRequired: [String]
    let sampleRows: [[String]] // best-effort rows for user to verify mapping
}

enum ColumnMappingStore {
    private static func key(kind: ColumnMappingKind, signature: String) -> String {
        "oei.mapping.\(kind.rawValue).\(signature)"
    }

    static func load(kind: ColumnMappingKind, headerSignature: String, defaults: UserDefaults = .standard) -> ColumnMapping? {
        let k = key(kind: kind, signature: headerSignature)
        guard let data = defaults.data(forKey: k) else { return nil }
        return try? JSONDecoder().decode(ColumnMapping.self, from: data)
    }

    static func save(_ mapping: ColumnMapping, defaults: UserDefaults = .standard) {
        let k = key(kind: mapping.kind, signature: mapping.headerSignature)
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: k)
    }
}

