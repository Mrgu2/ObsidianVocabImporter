import Foundation

// Centralized Vault paths for this app.
// We keep a legacy dir for backward compatibility with older builds.
enum VaultSupportPaths {
    static let primaryDirName = ".obsidian-vocab-importer"
    static let legacyDirName = ".english-importer"

    static let importedIndexFileName = "imported_index.json"
    static let momoExportIndexFileName = "momo_exported_vocab.json"
    static let logFileName = "import_log.txt"
}

// Why JSON + hidden folder:
// - We want dedup across multiple imports and across machines.
// - Keeping the index inside the Vault makes it travel with the Vault (Obsidian Sync/iCloud/git).
// - A hidden folder avoids cluttering the user's note list.
final class ImportedIndexStore {
    struct IndexSets: Sendable {
        var sentences: Set<String>
        var vocab: Set<String>
    }

    private struct IndexFile: Codable {
        var sentences: [String]
        var vocab: [String]
    }

    // Primary (current) directory + index.
    let directoryURL: URL
    let indexURL: URL

    // Legacy (read-only) directory + index for migration.
    let legacyDirectoryURL: URL
    let legacyIndexURL: URL

    init(vaultURL: URL) {
        self.directoryURL = vaultURL.appendingPathComponent(VaultSupportPaths.primaryDirName, isDirectory: true)
        self.indexURL = directoryURL.appendingPathComponent(VaultSupportPaths.importedIndexFileName, isDirectory: false)

        self.legacyDirectoryURL = vaultURL.appendingPathComponent(VaultSupportPaths.legacyDirName, isDirectory: true)
        self.legacyIndexURL = legacyDirectoryURL.appendingPathComponent(VaultSupportPaths.importedIndexFileName, isDirectory: false)
    }

    func hasAnyIndexFile() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: indexURL.path) || fm.fileExists(atPath: legacyIndexURL.path)
    }

    func load() throws -> IndexSets {
        let fm = FileManager.default

        func readIndex(at url: URL, backupDir: URL) -> IndexSets {
            guard fm.fileExists(atPath: url.path) else { return IndexSets(sentences: [], vocab: []) }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let decoded = try JSONDecoder().decode(IndexFile.self, from: data)
                return IndexSets(sentences: Set(decoded.sentences), vocab: Set(decoded.vocab))
            } catch {
                // Be resilient to sync conflicts / manual edits that corrupt JSON.
                // Keep a backup so the user can inspect what went wrong.
                try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let ts = f.string(from: Date())
                let name = "\(VaultSupportPaths.importedIndexFileName).corrupt-\(ts)-\(UUID().uuidString).bak"
                let backupURL = backupDir.appendingPathComponent(name, isDirectory: false)
                try? fm.moveItem(at: url, to: backupURL)
                return IndexSets(sentences: [], vocab: [])
            }
        }

        let primary = readIndex(at: indexURL, backupDir: directoryURL)
        let legacy = readIndex(at: legacyIndexURL, backupDir: legacyDirectoryURL)

        var merged = primary
        merged.sentences.formUnion(legacy.sentences)
        merged.vocab.formUnion(legacy.vocab)
        return merged
    }

    func save(_ sets: IndexSets) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Sorted for stable diffs (useful if the Vault is version-controlled).
        let file = IndexFile(
            sentences: sets.sentences.sorted(),
            vocab: sets.vocab.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try AtomicFileWriter.write(data, to: indexURL)
    }
}
