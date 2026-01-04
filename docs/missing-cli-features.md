# Claude CLIにあってvibing.nvimにまだない機能

**作成日**: 2026-01-04
**参照**: ADR 003 - Agent SDK vs CLI Architecture Decision

## 概要

このドキュメントは、Claude CLIに存在するがvibing.nvimにまだ実装されていない機能を列挙します。各機能について、実装優先度と複雑度の評価も含みます。

## 未実装機能の一覧

### 1. `.gitignore` 統合

**CLI機能**:
- `.gitignore` パターンに基づいてファイルを自動除外
- 不要なファイルがコンテキストに含まれない

**実装可能性**:
- ✅ 実装容易
- `.gitignore` ファイルを読み込んでパターンマッチング
- Globツールやファイル操作時にフィルタリング

**優先度**: 中
**実装複雑度**: 低

**現状の代替手段**:
- ユーザーが手動でコンテキスト選択

---

### 2. プロジェクト初期化 (`/init`)

**CLI機能**:
- コードベースを分析してCLAUDE.mdを自動生成
- git、ファイル構造、依存関係を解析
- プロジェクトの概要、技術スタック、規約を推測

**実装可能性**:
- ⚠️ 実装可能だが複雑
- ファイルシステムスキャン、git統合、コード解析が必要
- vibing.nvimの要件としては優先度低

**優先度**: 低
**実装複雑度**: 高

**現状の代替手段**:
- ユーザーが手動でCLAUDE.md作成

---

### 3. Quick memory更新 (`#` prefix)

**CLI機能**:
- チャット中に `# 覚えておくこと` と入力するとCLAUDE.mdに追記
- インライン記憶更新機能

**実装可能性**:
- ✅ 実装容易
- ファイル追記のみ (数行のコード)
- Slash commandやカスタムロジックで実装可能

**優先度**: 中
**実装複雑度**: 低

**現状の代替手段**:
- Slash commandで代替可能

**推奨実装方法**:
- Slash command `/remember <text>` を追加
- または `#` prefix検出ロジックをチャット送信時に実装

---

### 4. 組み込みSlash commands

**CLI組み込みコマンド**:
- `/clear` - 会話をクリアして新規開始
- `/rewind` - 会話履歴を遡る
- `/config` - インタラクティブ設定UI
- `/export` - 会話をファイルに出力
- `/hooks` - Hook設定UI

**vibing.nvim実装状況**:
- ✅ `/clear` 相当: `:VibingChat` で新規チャット作成
- ✅ `/export` 相当: チャットは自動的にMarkdownファイルとして保存
- ❌ `/rewind` - 未実装
- ❌ `/config` - 未実装
- ❌ `/hooks` - 未実装

**実装可能性**:
- `/rewind`: 中程度 (セッション履歴管理が必要)
- `/config`: 複雑 (UI実装必要)
- `/hooks`: 複雑 (UI実装必要)

**優先度**: `/rewind` (中), `/config` (低), `/hooks` (低)
**実装複雑度**: `/rewind` (中), `/config` (高), `/hooks` (高)

**現状の代替手段**:
- `/rewind`: セッション履歴はMarkdownファイルとして保存済み (手動で編集可能)
- `/config`, `/hooks`: Neovim設定で代替

---

### 5. GitHub App自動インストール

**CLI機能**:
- `/install-github-app` でGitHub統合を自動セットアップ
- OAuth認証フローを処理

**実装可能性**:
- ❌ 実装不可能
- OAuth認証フローはCLI/デスクトップアプリ固有
- 手動で `.claude.json` 設定が必要

**優先度**: 低
**実装複雑度**: 不可能

**現状の代替手段**:
- 手動設定推奨

---

### 6. Worktree管理

**CLI機能**:
- デスクトップアプリでWorktreeを管理
- 複数のブランチを同時に作業

**実装可能性**:
- ⚠️ 実装可能だが複雑
- git worktree操作のラッパー

**優先度**: 低
**実装複雑度**: 高

**現状の代替手段**:
- git直接使用で十分

---

## vibing.nvimが既に提供する同等以上の機能

vibing.nvimは以下の機能でClaude CLIと同等、またはそれ以上の機能を提供しています：

| vibing.nvim機能                           | CLI同等機能            | 優位性             |
| ----------------------------------------- | ---------------------- | ------------------ |
| **`settingSources: ['user', 'project']`** | CLAUDE.md auto-load    | ✅ 同等            |
| **Permission Builder UI**                 | `/permissions`         | ✅ より詳細        |
| **Concurrent sessions**                   | Single session         | ✅ vibing.nvim優位 |
| **Message timestamps**                    | なし                   | ✅ vibing.nvim独自 |
| **Granular permission rules**             | Basic `--allowedTools` | ✅ vibing.nvim優位 |
| **Session persistence with metadata**     | Basic history          | ✅ vibing.nvim優位 |
| **Custom MCP server (vibing-nvim)**       | なし                   | ✅ vibing.nvim独自 |
| **Language config per session**           | なし                   | ✅ vibing.nvim独自 |
| **Diff viewer (gd)**                      | なし                   | ✅ vibing.nvim独自 |
| **Inline action queue**                   | なし                   | ✅ vibing.nvim独自 |

---

## 実装推奨度の評価

### 高優先度 (vibing.nvimで実装すべき)

❌ なし (既存機能で十分)

### 中優先度 (将来的に検討可能)

1. **`.gitignore` 統合**
   - コンテキスト自動フィルタリング
   - 実装複雑度: 低
   - メリット: ユーザーエクスペリエンス向上

2. **Quick memory更新 (`#` prefix または slash command)**
   - CLAUDE.mdへの追記を簡単に
   - 実装複雑度: 低
   - メリット: ワークフロー改善

3. **`/rewind` コマンド**
   - 会話履歴を遡る機能
   - 実装複雑度: 中
   - メリット: 長い会話でのナビゲーション改善

### 低優先度 (不要または代替可能)

1. **`/init`**
   - ユーザーが手動でCLAUDE.md作成
   - 実装複雑度: 高

2. **`/config`, `/hooks`**
   - Neovim設定で代替
   - 実装複雑度: 高

3. **GitHub App install**
   - 手動設定で十分
   - 実装複雑度: 不可能

4. **Worktree management**
   - git直接使用で十分
   - 実装複雑度: 高

---

## まとめ

ADR 003の分析に基づくと、Claude CLIにある機能のほとんどは：

1. ✅ vibing.nvimで既に実装済み (`settingSources` により)
2. ⚠️ vibing.nvimの要件に不要、または代替可能
3. ✅ vibing.nvimは独自の強力な機能を多数提供

**重要な発見**:
- CLAUDE.md自動読み込み、Slash commands、Skills、MCP serversはすべて既に実装済み
- CLI固有の利便性機能（`/init`, `/config`等）はvibing.nvimの要件に不必要
- vibing.nvimは並行実行、タイムスタンプ、細かい権限制御など、CLIにない機能を提供

**推奨アクション**:
- 中優先度機能（`.gitignore`統合、Quick memory、`/rewind`）の実装を検討
- 低優先度機能は現状維持で問題なし
