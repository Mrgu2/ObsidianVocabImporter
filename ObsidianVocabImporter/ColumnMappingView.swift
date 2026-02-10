import SwiftUI

struct ColumnMappingView: View {
    let pending: PendingColumnMapping
    let onCancel: () -> Void
    let onConfirm: (ColumnMapping) -> Void

    @State private var selectedIndexByField: [String: Int]

    init(pending: PendingColumnMapping, onCancel: @escaping () -> Void, onConfirm: @escaping (ColumnMapping) -> Void) {
        self.pending = pending
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        let schema = (pending.kind == .sentence) ? ColumnSchema.sentence : ColumnSchema.vocabulary
        var initial: [String: Int] = [:]
        initial.reserveCapacity(schema.fields.count)

        for f in schema.fields {
            if let suggested = pending.suggestedFieldToHeaderIndex[f.canonicalName] {
                initial[f.canonicalName] = suggested
            } else {
                initial[f.canonicalName] = -1
            }
        }
        _selectedIndexByField = State(initialValue: initial)
    }

    private var schema: ColumnSchema {
        pending.kind == .sentence ? .sentence : .vocabulary
    }

    private var missingRequired: [String] {
        schema.requiredCanonicalNames.filter { (selectedIndexByField[$0] ?? -1) < 0 }
    }

    private func fieldLabel(_ canonical: String) -> String {
        switch canonical {
        case "sentence": return "Sentence（英文句子）"
        case "word": return "Word（单词）"
        case "translation": return "Translation（释义/翻译）"
        case "phonetic": return "Phonetic（音标）"
        case "url": return "URL（来源链接）"
        case "date": return "Date（日期）"
        default: return canonical
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("列映射（\(pending.kind.displayName)）")
                .font(.headline)

            Text("无法从表头自动识别必需列，请手动选择。此映射会被记住：下次遇到相同表头会自动应用。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Form {
                Section("文件") {
                    HStack {
                        Text("路径")
                        Spacer()
                        Text(pending.fileURL.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Text("分隔符")
                        Spacer()
                        Text(pending.delimiter.displayName)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("映射") {
                    ForEach(schema.fields, id: \.canonicalName) { f in
                        Picker(fieldLabel(f.canonicalName), selection: Binding(
                            get: { selectedIndexByField[f.canonicalName] ?? -1 },
                            set: { selectedIndexByField[f.canonicalName] = $0 }
                        )) {
                            Text("None").tag(-1)
                            ForEach(Array(pending.header.enumerated()), id: \.offset) { idx, name in
                                Text("[\(idx)] \(name)").tag(idx)
                            }
                        }
                    }

                    if !missingRequired.isEmpty {
                        Text("缺少必需列：\(missingRequired.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("样例（前几行，便于核对）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pending.header.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: " | "))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)

                        ForEach(Array(pending.sampleRows.prefix(5).enumerated()), id: \.offset) { _, row in
                            Text(row.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | "))
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("保存并继续") {
                    var fieldToIndex: [String: Int] = [:]
                    fieldToIndex.reserveCapacity(selectedIndexByField.count)
                    for (k, v) in selectedIndexByField where v >= 0 {
                        fieldToIndex[k] = v
                    }
                    onConfirm(
                        ColumnMapping(
                            kind: pending.kind,
                            headerSignature: pending.headerSignature,
                            fieldToHeaderIndex: fieldToIndex
                        )
                    )
                }
                .disabled(!missingRequired.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 820, height: 560)
    }
}

