import Foundation

enum AtomicWriteError: Error {
    case invalidParentDirectory
}

struct AtomicFileWriter {
    // Why atomic writes:
    // Obsidian folders are often synced (Obsidian Sync, iCloud, Dropbox, git).
    // Writing via a temp file + replace prevents partially-written Markdown from being
    // observed by the sync engine or Obsidian itself, reducing conflict/corruption risk.
    static func writeString(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: [.atomic])

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
    }

    static func appendStringAtomically(_ string: String, to url: URL) throws {
        let fm = FileManager.default
        var existing = Data()
        if fm.fileExists(atPath: url.path) {
            existing = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        var combined = Data()
        combined.reserveCapacity(existing.count + string.utf8.count)
        combined.append(existing)
        combined.append(Data(string.utf8))
        try write(combined, to: url)
    }
}
