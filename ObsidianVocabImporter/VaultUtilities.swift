import Foundation

enum VaultUtilities {
    static func persistedVaultURL(defaults: UserDefaults = .standard) -> URL? {
        guard let vaultPath = defaults.string(forKey: RecentSelectionKeys.lastVaultPath) else { return nil }
        let url = URL(fileURLWithPath: vaultPath, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return nil
    }

    static func outputRootURL(vaultURL: URL, preferences: PreferencesSnapshot) -> URL {
        vaultURL.appendingPathComponent(preferences.outputRootRelativePath, isDirectory: true)
    }

    static func dailyReviewFileURL(vaultURL: URL, preferences: PreferencesSnapshot, dateYMD: String) -> URL {
        let root = outputRootURL(vaultURL: vaultURL, preferences: preferences)
        if preferences.organizeByDateFolder {
            return root
                .appendingPathComponent(dateYMD, isDirectory: true)
                .appendingPathComponent("Review.md", isDirectory: false)
        }
        return root.appendingPathComponent("\(dateYMD).md", isDirectory: false)
    }

    static func relativePath(from vault: URL, to file: URL) -> String {
        let vaultPath = vault.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(vaultPath + "/") {
            return String(filePath.dropFirst(vaultPath.count + 1))
        }
        return file.lastPathComponent
    }

    static func readTextFileLossy(_ url: URL) -> String? {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .macOSRoman]
            for enc in encodings {
                if let s = String(data: data, encoding: enc) {
                    return s
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}

