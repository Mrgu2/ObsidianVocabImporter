import Foundation

// Separate index for MoMo wordbook export.
// Why store it inside the Vault:
// - The user often syncs/moves the Vault across machines.
// - Keeping export dedup state in the Vault makes "export only new words" stable everywhere.
// - Hidden folder avoids cluttering note lists.
final class MomoExportIndexStore {
    private struct IndexFile: Codable {
        var vocab: [String]
    }

    // Primary (current) directory + index.
    let directoryURL: URL
    let indexURL: URL

    // Legacy (read-only) directory + index.
    let legacyDirectoryURL: URL
    let legacyIndexURL: URL

    init(vaultURL: URL) {
        self.directoryURL = vaultURL.appendingPathComponent(VaultSupportPaths.primaryDirName, isDirectory: true)
        self.indexURL = directoryURL.appendingPathComponent(VaultSupportPaths.momoExportIndexFileName, isDirectory: false)

        self.legacyDirectoryURL = vaultURL.appendingPathComponent(VaultSupportPaths.legacyDirName, isDirectory: true)
        self.legacyIndexURL = legacyDirectoryURL.appendingPathComponent(VaultSupportPaths.momoExportIndexFileName, isDirectory: false)
    }

    func load() throws -> Set<String> {
        let fm = FileManager.default

        func readSet(at url: URL, backupDir: URL) -> Set<String> {
            guard fm.fileExists(atPath: url.path) else { return [] }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let decoded = try JSONDecoder().decode(IndexFile.self, from: data)
                return Set(decoded.vocab)
            } catch {
                // Resilient to sync conflicts / manual edits.
                try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let ts = f.string(from: Date())
                let name = "\(VaultSupportPaths.momoExportIndexFileName).corrupt-\(ts)-\(UUID().uuidString).bak"
                let backupURL = backupDir.appendingPathComponent(name, isDirectory: false)
                try? fm.moveItem(at: url, to: backupURL)
                return []
            }
        }

        let primary = readSet(at: indexURL, backupDir: directoryURL)
        let legacy = readSet(at: legacyIndexURL, backupDir: legacyDirectoryURL)
        return primary.union(legacy)
    }

    func save(_ ids: Set<String>) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Sorted for stable diffs.
        let file = IndexFile(vocab: ids.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try AtomicFileWriter.write(data, to: indexURL)
    }
}
