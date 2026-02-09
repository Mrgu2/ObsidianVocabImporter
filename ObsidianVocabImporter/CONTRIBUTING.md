# Contributing

Thanks for contributing to **Obsidian Vocab Importer**.

## Development

Prereqs:

- macOS 13+
- Xcode 15+ (Swift 5.9+)

Run:

1. Open `ObsidianVocabImporter/ObsidianVocabImporter.xcodeproj`
2. Select scheme `ObsidianVocabImporter`
3. Build & run

## Adding Support For New CSV/TSV Exports

This project supports:

- delimiter auto-detect: `,` / `Tab` / `;`
- header normalization + alias matching
- manual column mapping (stored in `UserDefaults`)

To add more header aliases:

1. Update the alias lists in `ObsidianVocabImporter/ObsidianVocabImporter/ColumnSchema.swift`
2. Keep aliases short and representative (e.g. `term`, `meaning`, `例句`, `音标`)
3. Prefer adding aliases over hard-coding exporter-specific file names

To report an exporter format issue:

- Open an issue and include the header row (and 1-2 sample data rows) with sensitive content removed.

## Code Style / Safety

- Avoid destructive edits to existing Markdown; prefer append-only behavior.
- Keep the Markdown output deterministic (stable ordering, stable formatting).
- When touching parsing logic, consider encodings and line endings.
