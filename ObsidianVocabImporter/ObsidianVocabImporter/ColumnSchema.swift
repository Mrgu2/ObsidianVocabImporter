import Foundation

enum ColumnMappingKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case sentence
    case vocabulary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sentence: return "句子"
        case .vocabulary: return "词汇"
        }
    }
}

struct ColumnField: Hashable, Sendable {
    let canonicalName: String
    let aliases: [String]
    let required: Bool

    var normalizedAliases: [String] {
        aliases.map { HeaderNormalizer.normalize($0) }.filter { !$0.isEmpty }
    }
}

struct ColumnSchema: Sendable {
    let kind: ColumnMappingKind
    let fields: [ColumnField]

    var requiredCanonicalNames: [String] {
        fields.filter { $0.required }.map { $0.canonicalName }
    }

    static let sentence: ColumnSchema = ColumnSchema(
        kind: .sentence,
        fields: [
            ColumnField(canonicalName: "sentence", aliases: ["sentence", "text", "english", "en", "content", "例句"], required: true),
            ColumnField(canonicalName: "translation", aliases: ["translation", "cn", "chinese", "meaning", "释义", "翻译", "中文"], required: false),
            ColumnField(canonicalName: "url", aliases: ["url", "link", "source", "来源"], required: false),
            ColumnField(canonicalName: "date", aliases: ["date", "time", "created", "added", "日期"], required: true)
        ]
    )

    static let vocabulary: ColumnSchema = ColumnSchema(
        kind: .vocabulary,
        fields: [
            ColumnField(canonicalName: "word", aliases: ["word", "vocabulary", "vocab", "term", "单词"], required: true),
            ColumnField(canonicalName: "phonetic", aliases: ["phonetic", "ipa", "pronunciation", "音标"], required: false),
            ColumnField(canonicalName: "translation", aliases: ["translation", "cn", "chinese", "meaning", "释义", "翻译", "中文"], required: false),
            ColumnField(canonicalName: "date", aliases: ["date", "time", "created", "added", "日期"], required: true)
        ]
    )
}

struct AutoColumnMappingResult: Sendable {
    let kind: ColumnMappingKind
    let fieldToHeaderIndex: [String: Int]
    let missingRequired: [String]
}

enum ColumnSchemaMatcher {
    static func autoMap(schema: ColumnSchema, headerIndexMap: [String: Int]) -> AutoColumnMappingResult {
        var out: [String: Int] = [:]
        out.reserveCapacity(schema.fields.count)

        for f in schema.fields {
            var matched: Int? = nil
            for a in f.normalizedAliases {
                if let idx = headerIndexMap[a] {
                    matched = idx
                    break
                }
            }
            if let matched {
                out[f.canonicalName] = matched
            }
        }

        let missing = schema.requiredCanonicalNames.filter { out[$0] == nil }
        return AutoColumnMappingResult(kind: schema.kind, fieldToHeaderIndex: out, missingRequired: missing)
    }
}

