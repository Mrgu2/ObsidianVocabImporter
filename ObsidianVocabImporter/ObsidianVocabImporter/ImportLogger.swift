import Foundation

struct ImportLogger {
    let logURL: URL
    let legacyLogURL: URL

    init(vaultURL: URL) {
        let dir = vaultURL.appendingPathComponent(VaultSupportPaths.primaryDirName, isDirectory: true)
        self.logURL = dir.appendingPathComponent(VaultSupportPaths.logFileName, isDirectory: false)

        let legacyDir = vaultURL.appendingPathComponent(VaultSupportPaths.legacyDirName, isDirectory: true)
        self.legacyLogURL = legacyDir.appendingPathComponent(VaultSupportPaths.logFileName, isDirectory: false)
    }

    func appendSession(title: String, lines: [String]) throws {
        var payload = "\n[\(timestamp())] \(title)\n"
        for line in lines {
            payload += "- \(line)\n"
        }
        try AtomicFileWriter.appendStringAtomically(payload, to: logURL)
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
