# Obsidian Vocab Importer

Import vocabulary and sentences CSV exports into Obsidian as review-ready Markdown, with deduplication.

Swift 5.9 + SwiftUI 的轻量级 macOS 原生应用：把英语学习软件导出的两类 CSV（句子表 + 词汇表）一键导入 Obsidian Vault，按日期生成便于复习的 Markdown，并支持多次导入查重。

Vocab Importer for Obsidian

## 1. 运行方式

- 用 Xcode 打开：`ObsidianVocabImporter/ObsidianVocabImporter.xcodeproj`
- 选择 Scheme：`ObsidianVocabImporter`
- 如需真机运行/Archive，请在 Target 的 Signing 中选择你自己的 Team（本项目默认 `Automatic`，不包含任何网络权限）。

> 说明：为了让导入器可以直接读写你选择的 Vault 文件夹，本项目默认不启用 App Sandbox（适合非上架分发的工具型应用）。

## 2. 使用说明

1. 打开应用。
   - 应用会记住上次选择的 Vault/CSV/导入模式（如果路径仍然存在，会在下次启动时自动恢复）。
2. 选择 **Obsidian Vault** 文件夹。
3. 选择导入模式：
   - `句子`：只导入句子 CSV
   - `词汇`：只导入词汇 CSV
   - `全部合并`：句子 + 词汇合并导入（同一天只生成一个文件）
4. 选择 CSV：
   - 句子 CSV：常见文件名 `SENTENCE LIST.csv`，表头固定：`Sentence, Translation, URL, Date`
   - 词汇 CSV：常见文件名 `VOCABULARY LIST.csv`，表头固定：`Word, Phonetic, Translation, Date`
5. 你也可以把 CSV **拖拽到窗口**，应用会通过表头自动识别并填充。
6. 点击 `刷新预览` 查看将要写入的日期分组、去重后的新增数量、以及每一天的 Markdown 预览。
7. 点击 `导入` 执行写入，完成后下方 `结果` 会显示写入了哪些文件、新增多少条、跳过多少重复。
8. `结果` 区域还提供快捷按钮：打开输出目录 / 打开导入索引 / 打开日志（便于检查查重与排错）。

## 2.1 墨墨单词本导出（纯单词）

有时你可能只想把你在 Obsidian 里积累的词汇导出为**纯单词列表**（一行一个），粘贴到墨墨单词本的“词本正文”，不需要例句。

本应用提供 `墨墨单词本导出（纯单词）` 模块：

- 导出来源：扫描 Vault 输出目录（默认 `English Clips/`），因此会包含“快速捕获”写入的单词
- `复制新增单词`：把“Vault 里未导出过的单词”复制到剪贴板
- `导出到 TXT…`：把“新增单词”追加写入到一个 `.txt` 文件（如果文件已存在会在末尾追加）
- `生成导出预览`：先生成一份预览文本，确认无误再导出

## 2.2 兼容与迁移（旧索引目录）

如果你曾使用旧版本应用，Vault 里可能存在旧目录：

- 旧目录：`<Vault>/.english-importer/`
- 新目录：`<Vault>/.obsidian-vocab-importer/`

本应用会**读取并合并**旧目录中的去重索引，确保升级后不会重复导入；同时只会把新的索引与日志写入到新目录，并**不会自动删除**旧目录（避免误删用户内容）。

> 说明：为了实现“多次导出不重复”，导出功能同样需要你先选择 Vault（用于保存去重索引）。

导出也会去重（防止你反复导出同一批 CSV 时重复粘贴）：

- 导出索引文件：`<Vault>/.obsidian-vocab-importer/momo_exported_vocab.json`
- 去重 key 与 Obsidian 导入一致：`vocab_ + sha1(lowercase(trim(word)))`

## 3. 输出到 Obsidian 的目录结构

默认输出根目录（Vault 内）：`English Clips`

- 默认开启“按日期建文件夹”时：
  - `English Clips/2026-02-09/Review.md`
- 关闭“按日期建文件夹”时：
  - `English Clips/2026-02-09.md`

`Merged` 模式下，同一天的词汇与句子都会写入同一个 `Review.md`，并使用分区标题保证阅读连续性。

## 4. Review.md 格式

每个日期文件顶部包含固定 YAML frontmatter：

```markdown
---
date: 2026-02-09
source: imported
tags: [english, review]
---
```

正文为“卡片式”条目（便于勾选复习），并且只有一个文件：

- 概览行（会自动更新成最新总数）
- 分区结构会根据“全部合并”策略有所不同（见下方）

词汇条目格式：

```markdown
- [ ] Word  /Phonetic/  %% id: vocab_xxx %%
  - 释义：Translation
```

> 说明：部分导出文件的 `Phonetic` 字段可能已经包含 `/.../`，导入器会自动规范化为“只保留一对斜杠”，避免出现 `//...//`。

句子条目格式：

```markdown
- [ ] Sentence  %% id: sent_xxx %%
  - 中文：Translation
  - 来源：URL   (若 URL 为空则省略)
```

> 追加写入规则：如果当天文件已存在，只会把“新增且不重复”的条目追加到各自分区末尾，并更新概览行。

> 概览行计数规则（更贴近复习场景）：
> - `Vocabulary/Sentences/Review` 分区里的条目计为“待复习（Active）”
> - `Mastered` 分区里的条目计为“已掌握（Mastered）”
> - 当存在 Mastered 条目时，概览行会显示 `Active (Mastered X)`，方便你知道还剩多少没复习完。

## 4.1 全部合并的三种策略（合并规则开关）

在 `Settings` 里可以选择“全部合并”的布局策略，以适配不同复习习惯：

1. **先词后句（默认）**
   - `## Vocabulary`
   - `## Sentences`
2. **按时间线交错**
   - 使用单一分区 `## Review`，在同一列表内交错排列词汇与句子（无真实时间戳时为“尽量交错”的稳定策略）。
3. **以句子为主**
   - `## Sentences` 在前，`## Vocabulary` 在后
   - 新增句子条目下会额外附加一行“相关词”，把当天词汇表中命中的单词列出来（方便边复习句子边复习词）

## 4.2 句子内高亮词汇（加粗）

在 `Settings` 里开启“句子内高亮当天词汇”后：

- 全部合并模式下，应用会把“当天词汇表”里的单词在句子中自动加粗，例如 `**result**`。
- 为避免误高亮，当前仅对“单个英文单词（>=3 字母）”做匹配与加粗。

## 4.3 标记掌握与自动归档（Mastered）

当你在 Obsidian 中把条目前的 `- [ ]` 勾选为 `- [x]` 后：

- 在后续导入（涉及同一天文件）或执行扫描维护时，应用会把已掌握条目移动到：
  - `## Mastered Vocabulary`
  - `## Mastered Sentences`
- 可选：为归档条目追加 `#mastered` 标签（Settings 开关）

你也可以在主界面使用 `维护（扫描/归档已掌握）`：

- `扫描预览（不写入）`：只统计会移动多少条，不改动文件
- `执行归档（写入）`：把已掌握条目移动到 Mastered 分区，并同步更新概览行（原子写入）

## 5. 自动补年份（Vocabulary Date 只有月日）

词汇 CSV 的 `Date` 可能只有 `MM-DD`（例如 `02-09`、`2-9`、`02/09`），应用需要补全年份后统一输出 `yyyy-MM-dd`。

偏好设置（Settings）里提供两种策略：

1. **使用当前系统年份（默认）**：无论是否同时选择句子 CSV，都使用当前系统年份（`Calendar.current`）。
2. **使用句子 CSV 中出现最多的年份**：如果同时选择了句子 CSV 且句子日期能解析出年份集合，则使用“出现次数最多的年份”；否则回退到系统年份。

## 6. 查重机制（多次导入不重复写入）

为了支持反复导入同一批 CSV 而不写入重复内容，应用会在 Vault 内维护一个隐藏索引：

- 索引目录：`<Vault>/.obsidian-vocab-importer/`
- 索引文件：`<Vault>/.obsidian-vocab-importer/imported_index.json`

为什么把索引放在 Vault 的隐藏目录：

- 查重需要长期保存“已经导入过的条目 id”。
- 索引跟随 Vault 一起同步（Obsidian Sync / iCloud / git 等），跨机器依然稳定。
- 隐藏目录避免污染你的笔记列表。

### 唯一 id 规则（稳定、跨机器一致）

- 句子条目 id
  - `normalizedSentence = trim + lowercase + 多空格压缩成单空格`
  - `normalizedURL = trim(url)`（允许为空）
  - `key = normalizedSentence + "|" + normalizedURL`
  - `id = "sent_" + sha1(key)`

- 词汇条目 id
  - `normalizedWord = lowercase(trim(word))`
  - `id = "vocab_" + sha1(normalizedWord)`

设计原因：

- 句子用 `sentence + url`：同一句子可能来自不同来源链接，如果只用 sentence 会误判为重复。
- 词汇只用 `word`：发音/释义可能变化，但学习复习的实体仍是同一个单词。

### 文件级自愈（避免索引丢失导致重复）

每条条目都会把 `id:` 写进 Markdown。

- 如果某天的 `Review.md` 已经包含某些 `sent_...` / `vocab_...`，即使索引文件丢失，导入器也会先扫描现有文件的 id，再去重追加，从而避免重复。

## 7. 解析失败与日志

任何解析失败的行都会：

- 在 UI 预览中计数展示（`解析失败`）
- 在导入时写入日志：`<Vault>/.obsidian-vocab-importer/import_log.txt`

## 8. 性能与鲁棒性说明

- CSV 解析：项目内置轻量 CSV parser（支持 RFC4180 基本规则：引号、逗号、换行、双引号转义），不依赖大型第三方库。
- 大文件不冻结：解析与生成预览/写入都在后台 `Task.detached` 执行，UI 通过 `ProgressView` 展示进度。
- 原子写入：所有写文件都采用“临时文件写入 + replace”的方式，减少 Obsidian/同步工具看到半写入文件导致冲突的概率。
- 避免覆盖手动编辑：导入时会重新读取目标 Markdown 文件并基于“最新内容”追加条目；预览只用于展示，不会直接拿预览文本去覆盖现有文件。
- Markdown 稳定性：如果 CSV 字段里包含换行符，导入器会在渲染时把它们压缩为单行（空白折叠为一个空格），避免破坏列表缩进结构。
- 冲突预警：预览阶段会尽量提示“Vault 不可写 / 目标文件不可写 / 文件可能被占用 / 同一天文件过大”等问题；遇到“错误”预警时会禁用导入，你仍可选择只预览与检查。

## 9. 已知限制

- 日期会做日历合法性校验（例如 `2/30` 会被视为无效并计入“解析失败”）。
- CSV 表头需要能识别到“必需列”（句子：Sentence + Date；词汇：Word + Date）。如果自动识别失败，可通过“列映射”手动指定。
- 如果你手动大幅修改了 `Review.md` 的分区标题（`## Vocabulary` / `## Sentences`）或删除了 `id:` 行，导入器可能无法在原分区内追加或无法可靠去重。

## 10. 输入适配（表头别名 / 分隔符 / 列映射）

为适配不同软件的导出格式，导入器对输入做了更宽松的兼容：

### 10.1 分隔符自动识别

## 11. Notarization（打包与公证脚本）

如果你想把 `.app` 分发给别人（例如下载解压后直接拖进 Applications），推荐使用 **Developer ID 签名 + Notarization 公证**，这样用户打开时不会遇到一堆安全警告，分发体验更像“正经工具”。

本项目提供一键脚本（生成 ZIP 和/或 DMG，并提交 notarization，等待完成后自动 stapling）：

- 脚本：`./scripts/release_notarize.sh`

### 11.1 前置条件

1. 安装 Xcode（需要 `xcodebuild` / `notarytool` / `stapler`）。
2. 拥有 Apple Developer 账号，并在钥匙串里安装 `Developer ID Application` 证书。
3. 在 Xcode 的 Target Signing 中选择你自己的 Team，并确保启用 Hardened Runtime（Xcode 默认会处理）。

### 11.2 推荐：使用 notarytool keychain profile

先在本机保存凭证（只需做一次）：

```bash
xcrun notarytool store-credentials "ovi-notary" --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
```

然后一键打包公证（示例：生成 DMG）：

```bash
export OVI_NOTARY_PROFILE="ovi-notary"
export OVI_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
./scripts/release_notarize.sh --format dmg
```

输出会在 `ObsidianVocabImporter/dist/<timestamp>/` 下生成 `ObsidianVocabImporter.dmg`（或 zip）。

### 11.3 不使用 profile（可选）

```bash
export OVI_APPLE_ID="you@example.com"
export OVI_TEAM_ID="TEAMID"
export OVI_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export OVI_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
./scripts/release_notarize.sh --format zip
```

支持：

- `,`（CSV）
- `Tab`（TSV）
- `;`（分号分隔）

应用会读取文件前 64KB，并在第一条非空行中统计分隔符出现次数，选择最可能的分隔符进行解析。

### 10.2 表头别名（自动匹配）

应用会对表头做“归一化”（忽略大小写、空格/下划线/连字符/常见标点差异），并尝试按别名匹配字段。

句子（必需：`Sentence` + `Date`）常见别名示例：

- `Sentence`: `sentence`, `text`, `english`, `content`, `例句`
- `Translation`: `translation`, `meaning`, `释义`, `翻译`, `中文`
- `URL`: `url`, `link`, `source`, `来源`
- `Date`: `date`, `time`, `created`, `added`, `日期`

词汇（必需：`Word` + `Date`）常见别名示例：

- `Word`: `word`, `vocabulary`, `vocab`, `term`, `单词`
- `Phonetic`: `phonetic`, `ipa`, `pronunciation`, `音标`
- `Translation`: 同上
- `Date`: 同上

### 10.3 列映射（兜底）

如果自动识别仍无法找到“必需列”，应用会弹出“列映射”窗口让你手动选择：

- 每个字段选择对应的 CSV 列（可选 `None`）
- 显示前几行样例便于核对
- 保存后会记住：下次遇到相同表头会自动应用

映射存储在 `UserDefaults`，key 形式为：`oei.mapping.<kind>.<headerSignature>`。
