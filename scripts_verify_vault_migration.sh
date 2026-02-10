#!/usr/bin/env bash
set -euo pipefail

# End-to-end verification for:
# - legacy index dir read-only merge (.english-importer)
# - primary dir write (.obsidian-vocab-importer)
#
# Usage:
#   ./scripts_verify_vault_migration.sh            # uses a temp vault under /tmp
#   ./scripts_verify_vault_migration.sh /path/to/Vault
#
# Notes:
# - If you pass a real Vault path, this script will WRITE to it (creates/updates .obsidian-vocab-importer).
# - The temp-vault mode is safe and recommended.

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/ObsidianVocabImporter"

VAULT_PATH="${1:-}"
TEMP_VAULT=""

if [[ -z "$VAULT_PATH" ]]; then
  TEMP_VAULT="$(mktemp -d "/tmp/ovi-vault-XXXXXX")"
  VAULT_PATH="$TEMP_VAULT"
fi

cleanup() {
  if [[ -n "$TEMP_VAULT" && -d "$TEMP_VAULT" ]]; then
    rm -rf "$TEMP_VAULT"
  fi
}
trap cleanup EXIT

echo "Vault: $VAULT_PATH"

# Create legacy index dir + file.
mkdir -p "$VAULT_PATH/.english-importer"

cat > "$VAULT_PATH/.english-importer/imported_index.json" <<'JSON'
{
  "sentences": [],
  "vocab": [
    "vocab_d0be2dc421be4fcd0172e5afceea3970e2f3d940"
  ]
}
JSON

# Create an existing Markdown file with an ID not present in legacy index (to force full scan if needed).
mkdir -p "$VAULT_PATH/English Clips/2026-02-09"
cat > "$VAULT_PATH/English Clips/2026-02-09/Review.md" <<'MD'
---
date: 2026-02-09
source: imported
tags: [english, review]
---

**Overview:** Vocabulary: 1 | Sentences: 0

## Vocabulary
- [ ] banana
  - 释义：香蕉
  - id: vocab_250e77f12a5ab6972a0895d290c4792f0a326ea8

MD

# Create vocab CSV: apple (in legacy index), banana (in markdown), cherry (new), plus one invalid row to trigger log.
CSV_PATH="$VAULT_PATH/VOCABULARY LIST.csv"
cat > "$CSV_PATH" <<'CSV'
Word,Phonetic,Translation,Date
apple,,苹果,2-9
banana,,香蕉,2-9
cherry,,樱桃,2-9
,,(invalid word),2-9
CSV

cat > /tmp/ovi_verify_harness.swift <<'EOF'
import Foundation

@main
struct Main {
    static func main() throws {
        let vaultPath = ProcessInfo.processInfo.environment["OVI_VAULT_PATH"] ?? ""
        if vaultPath.isEmpty {
            fputs("Missing OVI_VAULT_PATH\n", stderr)
            exit(2)
        }
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let csvURL = vaultURL.appendingPathComponent("VOCABULARY LIST.csv")

        // Prepare plan: should add only "cherry" as new (apple/banana duplicates).
        let plan = try ImportPlanner.preparePlan(
            vaultURL: vaultURL,
            sentenceCSVURL: nil,
            vocabCSVURL: csvURL,
            mode: .vocabulary,
            progress: nil
        )

        if plan.totalNewVocab != 1 {
            fputs("FAILED: expected totalNewVocab=1, got \(plan.totalNewVocab)\n", stderr)
            exit(2)
        }
        if plan.parseFailures.isEmpty {
            fputs("FAILED: expected parseFailures>0 (invalid row), got 0\n", stderr)
            exit(2)
        }

        // Import: should create primary index + log (because parseFailures exist).
        _ = try ImportPlanner.performImport(plan: plan, vaultURL: vaultURL, progress: nil)

        let fm = FileManager.default
        let primaryDir = vaultURL.appendingPathComponent(VaultSupportPaths.primaryDirName, isDirectory: true)
        let legacyDir = vaultURL.appendingPathComponent(VaultSupportPaths.legacyDirName, isDirectory: true)

        let primaryIndex = primaryDir.appendingPathComponent(VaultSupportPaths.importedIndexFileName)
        let primaryLog = primaryDir.appendingPathComponent(VaultSupportPaths.logFileName)
        let legacyIndex = legacyDir.appendingPathComponent(VaultSupportPaths.importedIndexFileName)

        if !fm.fileExists(atPath: legacyIndex.path) {
            fputs("FAILED: legacy index unexpectedly missing\n", stderr)
            exit(2)
        }
        if !fm.fileExists(atPath: primaryIndex.path) {
            fputs("FAILED: primary index not created at \(primaryIndex.path)\n", stderr)
            exit(2)
        }
        if !fm.fileExists(atPath: primaryLog.path) {
            fputs("FAILED: primary log not created at \(primaryLog.path)\n", stderr)
            exit(2)
        }

        // Ensure the Review.md contains cherry exactly once (by ID).
        let review = vaultURL
            .appendingPathComponent("English Clips", isDirectory: true)
            .appendingPathComponent("2026-02-09", isDirectory: true)
            .appendingPathComponent("Review.md", isDirectory: false)
        let text = (try? String(contentsOf: review, encoding: .utf8)) ?? ""
        let cherryID = VocabClip.makeID(word: "cherry")
        let occurrences = text.components(separatedBy: cherryID).count - 1
        if occurrences != 1 {
            fputs("FAILED: expected cherry id occurrences=1, got \(occurrences)\n", stderr)
            exit(2)
        }

        print("OK")
    }
}
EOF

export OVI_VAULT_PATH="$VAULT_PATH"

swiftc -O -o /tmp/ovi_verify_harness \
  /tmp/ovi_verify_harness.swift \
  "$APP_DIR/AtomicFileWriter.swift" \
  "$APP_DIR/CSVParser.swift" \
  "$APP_DIR/HeaderNormalizer.swift" \
  "$APP_DIR/ColumnSchema.swift" \
  "$APP_DIR/ColumnMappingStore.swift" \
  "$APP_DIR/Models.swift" \
  "$APP_DIR/Preferences.swift" \
  "$APP_DIR/ImportLogger.swift" \
  "$APP_DIR/ImportedIndexStore.swift" \
  "$APP_DIR/MomoExportIndexStore.swift" \
  "$APP_DIR/MomoWordExporter.swift" \
  "$APP_DIR/MarkdownUpdater.swift" \
  "$APP_DIR/ImporterViewModel.swift" \
  -framework AppKit -framework UniformTypeIdentifiers

/tmp/ovi_verify_harness

rm -f /tmp/ovi_verify_harness /tmp/ovi_verify_harness.swift

echo "Success."
if [[ -n "$TEMP_VAULT" ]]; then
  echo "(Temp vault cleaned: $TEMP_VAULT)"
else
  echo "(Real vault left intact: $VAULT_PATH)"
  echo "Created/updated: $VAULT_PATH/.obsidian-vocab-importer/"
fi

