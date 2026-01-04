# ADR 003: Agent SDK vs CLI Architecture Decision

## Status

Accepted

## Date

2026-01-04

## Context

vibing.nvimは現在、Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`) の `query()` API
を直接使用してClaude AIと統合しています。しかし、Claude CLIの `claude -p` (headless mode)
も同等の機能を提供しており、代替実装の可能性があります。

この調査では、現在のAgent SDK実装と `claude -p` CLI実装の徹底的な比較を行い、vibing.nvimの要件に最適なアーキテクチャを決定します。

### vibing.nvimの要件

1. **Neovimとの統合**: Luaから呼び出し可能なNode.js wrapper
2. **ストリーミング応答**: リアルタイムでテキストとツール使用を表示
3. **セッション管理**: チャットの継続と再開
4. **権限制御**: 細かい権限ルール (`canUseTool` コールバック)
5. **MCP統合**: vibing-nvim MCP serverの自動ロード
6. **カスタムロジック**:
   - `acceptEdits` モードの実装
   - Ask-listed toolsのresume session対策 (Issue #29)
   - 粒度の高いパターンマッチング (Bash, file path, domain)
7. **エラーハンドリング**: 詳細なエラーメッセージとユーザーガイダンス
8. **パフォーマンス**: 低レイテンシ、高速起動
9. **メンテナンス性**: npm依存の管理、バージョン管理

### 比較対象

**オプション1: Agent SDK (現在の実装)**

- `@anthropic-ai/claude-agent-sdk` パッケージを直接使用
- `query()` APIでin-process実行
- `bin/agent-wrapper.mjs` でカスタムロジックを実装

**オプション2: CLI (`claude -p`)**

- Claude CLIを子プロセスとして起動
- `--output-format stream-json` でストリーミング
- `--allowedTools`, `--permission-mode` などのフラグで制御

## Decision

**Agent SDK (`query()` API) を継続使用する**

vibing.nvimは現在のAgent SDK実装を維持し、`claude -p` CLIへの移行は行わないことを決定しました。

### 主な理由

1. **カスタム権限制御の必要性**
   - ADR 001で詳述したように、vibing.nvimは複雑な権限ロジックを `canUseTool` コールバックで実装
   - `claude -p` のフラグベースの権限制御では実現不可能

2. **CLI固有機能は既に実装済み**
   - `settingSources: ['user', 'project']` でCLAUDE.md、Slash commands、Skills、MCP serversすべて自動読み込み
   - CLI移行で得られる新機能は**ほぼゼロ**

3. **依存関係の管理**
   - Agent SDKはnpm依存として管理され、`package.json` でバージョン固定可能
   - CLIはグローバルインストールが必要で、バージョン管理が困難

4. **パフォーマンス**
   - Agent SDKはin-process実行で起動オーバーヘッドなし
   - CLIは子プロセス起動のオーバーヘッドあり

5. **エラーハンドリングの柔軟性**
   - Agent SDKは直接try-catchでエラーをハンドリング可能
   - CLIはstdoutパースとプロセス管理の複雑さあり

## Detailed Comparison

### 1. 機能比較マトリクス

| 機能                   | Agent SDK                | CLI (`claude -p`)                | vibing.nvimの要件 | 評価            |
| ---------------------- | ------------------------ | -------------------------------- | ----------------- | --------------- |
| **ストリーミング**     | ✅ Async generator       | ✅ `--output-format stream-json` | 必須              | 同等            |
| **セッション管理**     | ✅ `resume` option       | ✅ `--resume`, `--continue`      | 必須              | 同等            |
| **CLAUDE.md読み込み**  | ✅ `settingSources`      | ✅ Auto-load                     | 必須              | 同等 (実装済み) |
| **Slash commands**     | ✅ `settingSources`      | ✅ Auto-load                     | 必須              | 同等 (実装済み) |
| **Skills auto-load**   | ✅ `settingSources`      | ✅ Auto-load                     | 必須              | 同等 (実装済み) |
| **権限制御**           | ✅ `canUseTool` callback | ⚠️ Flags only                    | 必須              | SDK優位         |
| **MCP統合**            | ✅ `settingSources`      | ✅ Auto-load                     | 必須              | 同等 (実装済み) |
| **モード選択**         | ✅ `mode` option         | ✅ `--mode`                      | 必須              | 同等            |
| **モデル選択**         | ✅ `model` option        | ✅ `--model`                     | 必須              | 同等            |
| **カスタムロジック**   | ✅ Full flexibility      | ❌ Flags only                    | 必須              | SDK優位         |
| **依存管理**           | ✅ npm package           | ❌ Global binary                 | 重要              | SDK優位         |
| **起動時間**           | ✅ In-process            | ❌ Process spawn                 | 重要              | SDK優位         |
| **エラーハンドリング** | ✅ Direct try-catch      | ⚠️ Parse stdout                  | 重要              | SDK優位         |

### 2. 既知の問題比較

#### Agent SDK (現在の実装)

**Issue #29: Resume Session Bypass**

- **症状**: Resume sessionで `allowedTools` と `canUseTool` がバイパスされる
- **影響**: Ask-listed toolsが自動承認される
- **対策**: ADR 001で実装済み (resume sessionではask-listed toolsをdeny)
- **状態**: Workaround実装済み、ユーザーへのガイダンス提供

**permissionMode Bypass**

- **症状**: `permissionMode` を設定すると `canUseTool` が完全にバイパスされる
- **影響**: カスタム権限ロジックが無効化される
- **対策**: `permissionMode` を設定しない (ADR 001)
- **状態**: Workaround実装済み

#### CLI (`claude -p`)

**JSON Truncation Issue (Issue #913)**

- **症状**: 長いJSON応答が固定位置 (4000, 6000, 8000 chars) で切断される
- **影響**: 大きな構造化データの生成が不可能
- **対策**: なし (CLI側のバグ)
- **状態**: 未解決、回避不可能

**Missing Final Result Event (Issue #1920)**

- **症状**: Streaming JSONで最終 `{"type":"result"}` イベントが欠落
- **影響**: プロセスがハングする可能性
- **対策**: タイムアウト実装が必要
- **状態**: 未解決、回避策必要

**Stream Input Hang (Issue #3187)**

- **症状**: `--input-format stream-json` でマルチターンメッセージ時にハング
- **影響**: 複雑な会話フローが不可能
- **対策**: なし
- **状態**: 未解決

**Resume Bug (Issue #3188)**

- **症状**: `--resume <session-id>` がセッションIDを無視して新規セッション作成
- **影響**: セッション継続が不安定
- **対策**: なし
- **状態**: 未解決、信頼性に問題

**AllowedTools Reliability (Issue #563)**

- **症状**: `--allowedTools` フラグがnon-interactiveモードで信頼性が低い
- **影響**: 権限制御が不安定
- **対策**: なし
- **状態**: 未解決

### 3. カスタム権限制御の実装可能性

#### Agent SDK (現在の実装)

```javascript
queryOptions.canUseTool = async (toolName, input) => {
  // 1. acceptEdits mode: auto-approve Edit/Write
  if (permissionMode === 'acceptEdits' && (toolName === 'Edit' || toolName === 'Write')) {
    return { behavior: 'allow', updatedInput: input };
  }

  // 2. vibing-nvim MCP tools control
  if (toolName.startsWith('mcp__vibing-nvim__')) {
    return mcpEnabled
      ? { behavior: 'allow', updatedInput: input }
      : { behavior: 'deny', message: 'MCP integration disabled' };
  }

  // 3. Issue #29 workaround: deny ask-listed tools in resume sessions
  if (sessionId && askedTools.includes(toolName)) {
    return {
      behavior: 'deny',
      message: `Tool ${toolName} requires approval. Add to allow list for resume sessions.`,
    };
  }

  // 4. Granular pattern matching
  // - Bash(npm:*) - wildcard command match
  // - Read(src/**/*.ts) - file glob pattern
  // - WebFetch(github.com) - domain pattern
  if (allowedTools.length > 0) {
    const matches = allowedTools.some((pattern) => matchesPermission(toolName, input, pattern));
    if (!matches) {
      return { behavior: 'deny', message: `Tool ${toolName} not allowed` };
    }
  }

  // 5. Permission rules (path, command, pattern, domain-based)
  for (const rule of permissionRules) {
    const result = checkRule(rule, toolName, input);
    if (result === 'deny') {
      return { behavior: 'deny', message: rule.message };
    }
  }

  return { behavior: 'allow', updatedInput: input };
};
```

**実装可能**: ✅ 完全に実装可能

#### CLI (`claude -p`)

```bash
node -e "
const { spawn } = require('child_process');

const claude = spawn('claude', [
  '-p', 'Your prompt',
  '--output-format', 'stream-json',
  '--allowedTools', 'Read,Edit,Write',  # ❌ 粒度の高いパターンマッチング不可
  '--permission-mode', 'acceptEdits',   # ❌ canUseTool bypassed
  '--resume', sessionId
]);

// ❌ カスタムロジック実装不可
// ❌ Issue #29対策不可
// ❌ vibing-nvim MCP制御不可
// ❌ 粒度の高いルール実装不可

claude.stdout.on('data', (data) => {
  // Parse JSON Lines
});
"
```

**実装可能**: ❌ カスタム権限制御が実装不可能

### 4. CLI固有機能とAgent SDK実装状況

このセクションでは、「CLIにあってSDKにない機能」と、それらがvibing.nvimで実装可能かどうかを詳細に分析します。

#### 4.1. CLAUDE.md自動読み込み

**Claude CLI:**

- ✅ **自動で読み込む** - 設定不要
- プロジェクトルートの `CLAUDE.md` を自動検出
- 親ディレクトリを遡って検索
- ユーザーグローバル設定 (`~/.claude/CLAUDE.md`) も読み込み
- `claude` または `claude -p` 実行時に自動的にシステムプロンプトに注入

**Agent SDK:**

- ⚠️ **手動設定が必要** - デフォルトでは読み込まない
- `settingSources` パラメータで明示的に指定必要:

  ```javascript
  {
    settingSources: ['user', 'project']; // ユーザーとプロジェクト設定を読み込み
  }
  ```

- `settingSources` 未指定時は、CLAUDE.mdや`.claude/`ディレクトリを読み込まない

**vibing.nvimの実装状況:**

```javascript
// bin/agent-wrapper.mjs (line 297)
settingSources: ['user', 'project'],
```

- ✅ **既に実装済み**: vibing.nvimは `settingSources` を正しく設定
- ✅ CLAUDE.md自動読み込みが有効
- ✅ `.claude/commands/` slash commandsも読み込み
- ✅ `.claude/skills/` skillsも読み込み
- ✅ `~/.claude.json` MCP serversも読み込み

**結論**: CLI自動読み込みの利便性は、Agent SDKでも `settingSources` 設定で同等に実現可能。vibing.nvimは既に実装済み。

#### 4.2. CLI固有機能の一覧と実装可能性

| 機能                        | CLI                          | Agent SDK           | vibing.nvim実装状況    | 実装複雑度 |
| --------------------------- | ---------------------------- | ------------------- | ---------------------- | ---------- |
| **CLAUDE.md読み込み**       | ✅ Auto                      | ✅ `settingSources` | ✅ 実装済み (line 297) | 簡単       |
| **Slash commands**          | ✅ Auto                      | ✅ `settingSources` | ✅ 実装済み            | 簡単       |
| **Skills auto-load**        | ✅ Auto                      | ✅ `settingSources` | ✅ 実装済み            | 簡単       |
| **MCP servers**             | ✅ Auto                      | ✅ `settingSources` | ✅ 実装済み            | 簡単       |
| **`.gitignore` awareness**  | ✅ Built-in                  | ❌ Manual           | ❌ 未実装              | 低         |
| **Project init (`/init`)**  | ✅ Built-in                  | ❌ Manual           | ❌ 未実装              | 高         |
| **Quick memory (`#`)**      | ✅ Built-in                  | ❌ Manual           | ❌ 未実装              | 低         |
| **Built-in slash commands** | ✅ `/clear`, `/export`, etc. | ❌ Custom only      | ⚠️ 部分実装            | 中         |
| **Interactive hooks UI**    | ✅ `/hooks`                  | ❌ Manual config    | ❌ 未実装              | 高         |
| **GitHub App install**      | ✅ `/install-github-app`     | ❌ Manual           | ❌ 未実装              | 不可能     |
| **Worktree management**     | ✅ Desktop app               | ❌ Manual           | ❌ 未実装              | 高         |

#### 4.3. CLI固有機能の詳細分析

##### A. **プロジェクト初期化 (`/init`)**

**CLI機能**:

- コードベースを分析してCLAUDE.mdを自動生成
- git、ファイル構造、依存関係を解析
- プロジェクトの概要、技術スタック、規約を推測

**Agent SDK実装可能性**:

- ⚠️ **実装可能だが複雑**
- ファイルシステムスキャン、git統合、コード解析が必要
- vibing.nvimの要件としては**優先度低** (ユーザーが手動でCLAUDE.md作成可能)

**vibing.nvim実装状況**: ❌ 未実装 (不要と判断)

##### B. **Quick memory更新 (`#` prefix)**

**CLI機能**:

- チャット中に `# 覚えておくこと` と入力するとCLAUDE.mdに追記
- インライン記憶更新機能

**Agent SDK実装可能性**:

- ✅ **実装容易**
- ファイル追記のみ (数行のコード)
- Slash commandやカスタムロジックで実装可能

**vibing.nvim実装状況**: ❌ 未実装 (slash commandで代替可能)

##### C. **組み込みSlash commands**

**CLI組み込みコマンド**:

- `/clear` - 会話をクリアして新規開始
- `/rewind` - 会話履歴を遡る
- `/config` - インタラクティブ設定UI
- `/export` - 会話をファイルに出力
- `/hooks` - Hook設定UI

**Agent SDK実装可能性**:

- ✅ **ほぼすべて実装可能**
- `/clear` → セッションID削除 (簡単)
- `/rewind` → セッション履歴管理 (中程度)
- `/export` → Markdown出力 (簡単)
- `/config`, `/hooks` → UI実装必要 (複雑)

**vibing.nvim実装状況**:

- ✅ `/clear` 相当: `:VibingChat` で新規チャット作成
- ✅ `/export` 相当: チャットは自動的にMarkdownファイルとして保存
- ⚠️ `/rewind`, `/config`, `/hooks` は未実装

##### D. **`.gitignore` 統合**

**CLI機能**:

- `.gitignore` パターンに基づいてファイルを自動除外
- 不要なファイルがコンテキストに含まれない

**Agent SDK実装可能性**:

- ✅ **実装容易**
- `.gitignore` ファイルを読み込んでパターンマッチング
- Globツールやファイル操作時にフィルタリング

**vibing.nvim実装状況**: ❌ 未実装 (ユーザーが手動でコンテキスト選択)

##### E. **GitHub App自動インストール**

**CLI機能**:

- `/install-github-app` でGitHub統合を自動セットアップ
- OAuth認証フローを処理

**Agent SDK実装可能性**:

- ❌ **実装不可能**
- OAuth認証フローはCLI/デスクトップアプリ固有
- 手動で `.claude.json` 設定が必要

**vibing.nvim実装状況**: ❌ 未実装 (手動設定推奨)

#### 4.4. vibing.nvimが既に提供する同等以上の機能

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

#### 4.5. 実装推奨度の評価

**高優先度 (vibing.nvimで実装すべき)**:

- ❌ なし (既存機能で十分)

**中優先度 (将来的に検討可能)**:

- `.gitignore` 統合 (コンテキスト自動フィルタリング)
- Quick memory更新 (`#` prefix または slash command)

**低優先度 (不要または代替可能)**:

- `/init` (ユーザーが手動でCLAUDE.md作成)
- `/rewind` (セッション履歴はMarkdownファイルとして保存済み)
- `/config`, `/hooks` (Neovim設定で代替)
- GitHub App install (手動設定で十分)
- Worktree management (git直接使用で十分)

#### 4.6. 結論: CLI固有機能は代替可能

**重要な発見**:

1. ✅ **CLAUDE.md自動読み込み**: vibing.nvimは `settingSources` で既に実装済み
2. ✅ **Slash commands/Skills/MCP**: すべて `settingSources` で有効化済み
3. ⚠️ **CLI独自の利便性機能**: ほとんどがvibing.nvimの要件に不要、または代替可能
4. ✅ **vibing.nvim独自機能**: CLIにない機能を多数実装済み

**Agent SDK実装のメリットが明確化**:

- CLI固有機能の大部分は `settingSources` で実現可能
- vibing.nvimは既に適切に設定されており、CLI同等以上の機能を提供
- CLI移行で得られるメリットは**ほぼゼロ**
- 逆にCLI移行で失われる機能（カスタム権限制御、MCP制御等）が多数

### 5. 依存関係管理

#### Agent SDK

```json
{
  "dependencies": {
    "@anthropic-ai/claude-agent-sdk": "^0.1.76"
  }
}
```

**メリット**:

- ✅ `package.json` でバージョン固定
- ✅ `npm install` で自動インストール
- ✅ `package-lock.json` で完全な再現性
- ✅ CI/CDで確実にバージョン管理

**デメリット**:

- ⚠️ npm依存の追加 (vibing.nvimは既にnpm使用中のため影響なし)

#### CLI

**必要な依存**:

- ✅ グローバル `claude` コマンドのインストール
- ❌ バージョン管理が困難 (ユーザー環境依存)

**メリット**:

- ⚠️ npm不要 (しかしvibing.nvimは既にnpm使用中)

**デメリット**:

- ❌ ユーザーが手動で `claude` をインストール必要
- ❌ バージョン不一致のリスク
- ❌ CI/CDでバージョン固定が困難
- ❌ `which claude` でパス確認が必要

### 6. パフォーマンス比較

#### Agent SDK (In-process)

```javascript
import { query } from '@anthropic-ai/claude-agent-sdk';

const result = query({ prompt, options }); // ✅ 即座に実行開始
for await (const message of result) {
  // ストリーミング処理
}
```

**起動時間**: ~0ms (in-process)
**メモリ**: Node.js process内
**オーバーヘッド**: なし

#### CLI (Subprocess)

```javascript
const { spawn } = require('child_process');

const claude = spawn('claude', ['-p', prompt, '--output-format', 'stream-json']);
// ❌ プロセス起動オーバーヘッド (50-200ms)
// ❌ IPC通信オーバーヘッド
// ❌ stdoutパースオーバーヘッド

claude.stdout.on('data', (data) => {
  // ❌ JSON Linesパース必要
  const lines = data.toString().split('\n');
  for (const line of lines) {
    try {
      const message = JSON.parse(line);
    } catch (e) {
      // ❌ パースエラーハンドリング必要
    }
  }
});
```

**起動時間**: 50-200ms (process spawn)
**メモリ**: 別プロセス (追加メモリ)
**オーバーヘッド**: Subprocess起動 + IPC + パース

### 7. エラーハンドリング

#### Agent SDK

```javascript
try {
  const result = query({ prompt, options });
  for await (const message of result) {
    // ✅ 型安全なメッセージ処理
    if (message.type === 'assistant') {
      // ...
    }
  }
} catch (error) {
  // ✅ 直接エラーをキャッチ
  console.error('SDK Error:', error.message);
  // ✅ エラーの種類を正確に判別可能
}
```

**メリット**:

- ✅ try-catchで直接エラーハンドリング
- ✅ 型安全なメッセージ処理
- ✅ エラーの詳細情報が利用可能

#### CLI

```javascript
const claude = spawn('claude', ['-p', prompt]);

claude.on('error', (error) => {
  // ❌ プロセス起動エラーのみキャッチ
  console.error('Spawn error:', error);
});

claude.stderr.on('data', (data) => {
  // ❌ stderrからエラーメッセージをパース必要
  // ❌ フォーマットが不明確
});

claude.on('exit', (code) => {
  if (code !== 0) {
    // ❌ エラーの詳細が不明
  }
});

claude.stdout.on('data', (data) => {
  try {
    const message = JSON.parse(data.toString());
    if (message.type === 'error') {
      // ⚠️ JSON Linesフォーマットのエラーのみキャッチ
    }
  } catch (e) {
    // ❌ JSONパースエラー vs 実際のエラーの区別困難
  }
});
```

**デメリット**:

- ❌ 複数のエラーソース (spawn, stderr, exit code, JSON error)
- ❌ エラーの種類を判別困難
- ❌ JSONパースエラーと実際のエラーの区別が必要

### 8. 実装の複雑さ

#### Agent SDK (現在の実装)

**コード量**: ~925行 (`bin/agent-wrapper.mjs`)
**主な構成**:

- 引数パース: ~130行
- 権限ロジック: ~350行 (細かい制御のため)
- ストリーミング処理: ~150行
- ユーティリティ: ~295行

**複雑性の理由**:

- ✅ 細かい権限制御 (vibing.nvimの要件)
- ✅ パターンマッチング実装
- ✅ Issue #29対策
- ✅ エラーハンドリング

#### CLI実装 (仮想)

**推定コード量**: ~400-500行
**主な構成**:

- プロセス管理: ~100行
- stdoutパース: ~100行
- エラーハンドリング: ~100行
- 引数構築: ~100行
- IPC通信: ~100行

**複雑性の理由**:

- ❌ プロセス管理の複雑さ
- ❌ JSON Linesパース
- ❌ エラーソースの多重化
- ❌ しかしカスタム権限制御は実装不可能 (vibing.nvimの要件を満たせない)

### 9. ユースケース適合性

#### vibing.nvimの特殊要件

1. **権限制御の細かさ**
   - ✅ Agent SDK: `canUseTool` で完全制御可能
   - ❌ CLI: フラグのみ、カスタムロジック不可

2. **Issue #29対策**
   - ✅ Agent SDK: `canUseTool` で対策実装済み (ADR 001)
   - ❌ CLI: 対策不可能 (resume時の挙動をカスタマイズ不可)

3. **vibing-nvim MCP制御**
   - ✅ Agent SDK: `canUseTool` で有効/無効切り替え
   - ❌ CLI: MCPツールの個別制御不可

4. **パターンマッチング**
   - ✅ Agent SDK: `Bash(npm:*)`, `Read(src/**/*.ts)` 等を実装
   - ❌ CLI: `--allowedTools` は単純なリストのみ

5. **エラーメッセージのカスタマイズ**
   - ✅ Agent SDK: ユーザーフレンドリーなメッセージをカスタム生成
   - ❌ CLI: デフォルトメッセージのみ

## Consequences

### Positive

1. **✅ カスタム権限制御の継続**: vibing.nvimの複雑な権限要件を満たし続けられる
2. **✅ CLAUDE.md自動読み込みが既に実装済み**: `settingSources: ['user', 'project']` でCLI同等の機能を実現
3. **✅ CLI固有機能はほぼ代替済み**: Slash commands, Skills, MCP serversすべて有効化済み
4. **✅ 依存管理の信頼性**: npm packageとしてバージョン固定、CI/CDで再現性確保
5. **✅ パフォーマンス**: In-process実行で低レイテンシ
6. **✅ エラーハンドリングの柔軟性**: 直接try-catchでエラーをキャッチ
7. **✅ Issue #29対策の継続**: 既存のworkaroundを維持
8. **✅ メンテナンス性**: 既存のコードベースを維持、新規実装不要
9. **✅ vibing.nvim独自機能**: CLIにない機能を多数提供 (concurrent sessions, message timestamps, diff viewer, etc.)

### Negative

1. **❌ CLI既知問題の影響なし**: CLI特有の問題 (JSON truncation等) は影響しない (これは実際にはpositive)
2. **⚠️ Agent SDK Issue #29の影響継続**: ただしworkaround実装済み (ADR 001)
3. **⚠️ npm依存の継続**: しかしvibing.nvimは既にnpm使用中のため追加影響なし

### Risks and Mitigations

**Risk 1: Agent SDK Issue #29が悪化**

- _軽減策_: 既存workaround (ADR 001) が安定して動作
- _軽減策_: SDK更新時のテストカバレッジ (`tests/permission-logic.test.mjs`)

**Risk 2: Agent SDKのbreaking changes**

- _軽減策_: `package.json` でバージョン固定 (`^0.1.76`)
- _軽減策_: 更新時のregression test実施

**Risk 3: CLI実装の方が将来的に安定する可能性**

- _軽減策_: CLI既知問題が解決され、かつAgent SDK問題が悪化した場合のみ再検討
- _軽減策_: このADRで比較基準を明確化、将来の再評価を容易に

## Alternatives Considered

### Alternative 1: CLI (`claude -p`) への完全移行

**実装アプローチ**:

```javascript
const { spawn } = require('child_process');

function executeQuery(prompt, options) {
  const args = [
    '-p',
    prompt,
    '--output-format',
    'stream-json',
    '--allowedTools',
    options.allowedTools.join(','),
    '--permission-mode',
    options.permissionMode,
    '--mode',
    options.mode,
    '--model',
    options.model,
  ];

  if (options.sessionId) {
    args.push('--resume', options.sessionId);
  }

  const claude = spawn('claude', args);

  claude.stdout.on('data', (data) => {
    const lines = data.toString().split('\n');
    for (const line of lines) {
      if (line.trim()) {
        try {
          const message = JSON.parse(line);
          // Process message
        } catch (e) {
          console.error('Parse error:', e);
        }
      }
    }
  });
}
```

**Rejected because**:

1. ❌ カスタム権限制御が実装不可能 (vibing.nvimの核心要件)
2. ❌ Issue #29対策が実装不可能
3. ❌ vibing-nvim MCP制御が不可能
4. ❌ パターンマッチングが実装不可能
5. ❌ CLI既知問題 (JSON truncation, missing final result, resume bug) の影響
6. ❌ 依存管理が困難 (グローバルインストール必要)
7. ❌ パフォーマンス低下 (subprocess overhead)
8. ❌ エラーハンドリングの複雑化

**メリット**:

- ⚠️ 「CLI公式実装を使う」という心理的安心感のみ (技術的メリットなし)
- ⚠️ npm依存削減 (しかしvibing.nvimは既にnpm使用中)

**結論**: vibing.nvimの要件を満たせないため却下

### Alternative 2: ハイブリッドアプローチ (一部機能でCLI使用)

**実装アプローチ**:

- 通常: Agent SDK使用
- シンプルなタスク: CLI使用 (例: inline actions)

**Rejected because**:

1. ❌ 実装の複雑化 (2つの実装を維持)
2. ❌ 一貫性の欠如 (タスクによって挙動が異なる)
3. ❌ テストの複雑化
4. ❌ inline actionsも権限制御が必要 (CLIでは不可能)
5. ❌ メリットが不明確

### Alternative 3: Agent SDKの継続使用 (現状維持)

**✅ Accepted**

理由は上記 "Decision" セクション参照。

## References

### Issues and Discussions

**Agent SDK Issues**:

- [Issue #29](https://github.com/anthropics/claude-agent-sdk-typescript/issues/29) -
  Resume session bypasses allowedTools and canUseTool
- ADR 001: Permissions Ask Implementation and Agent SDK Constraints

**CLI Issues**:

- [Issue #913](https://github.com/eyaltoledano/claude-task-master/issues/913) - JSON Truncation at fixed positions
- [Issue #1920](https://github.com/anthropics/claude-code/issues/1920) - Missing Final Result Event in Streaming JSON Output
- [Issue #3187](https://github.com/anthropics/claude-code/issues/3187) - Stream JSON Input Hang
- [Issue #3188](https://github.com/anthropics/claude-code/issues/3188) - Resume Bug (ignores session ID)
- [Issue #563](https://github.com/anthropics/claude-code/issues/563) - AllowedTools Reliability in Non-Interactive Mode

### Documentation

**General Documentation**:

- [Claude Code CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [Run Claude Code Programmatically](https://code.claude.com/docs/en/headless)
- [Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Agent SDK Sessions](https://platform.claude.com/docs/en/agent-sdk/sessions)
- [Agent SDK Permissions](https://platform.claude.com/docs/en/agent-sdk/permissions)

**CLI-Specific Features**:

- [Using CLAUDE.MD Files](https://claude.com/blog/using-claude-md-files)
- [Slash Commands Documentation](https://code.claude.com/docs/en/slash-commands)
- [Connect Claude Code to Tools via MCP](https://code.claude.com/docs/en/mcp)
- [Agent SDK Skills Documentation](https://platform.claude.com/docs/en/agent-sdk/skills)
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- [Claude Code CLI Cheat Sheet](https://shipyard.build/blog/claude-code-cheat-sheet/)

**Comparison Articles**:

- [Claude Code vs. Claude Agent SDK Comparison](https://drlee.io/claude-code-vs-claude-agent-sdk-whats-the-difference-177971c442a9)

### Implementation

- `bin/agent-wrapper.mjs` (lines 1-925) - Current Agent SDK implementation
- `package.json` (line 44) - Agent SDK dependency (`^0.1.76`)
- ADR 001: Permissions Ask Implementation and Agent SDK Constraints
- ADR 002: Concurrent Execution Support

## Notes

### Decision Rationale Summary

この決定は、**技術的メリットとvibing.nvimの要件適合性**に基づいています：

1. **カスタム権限制御の必要性が絶対的**: vibing.nvimのユーザーは細かい権限制御を期待しており、CLI実装では実現不可能
2. **CLAUDE.md自動読み込みは既に実装済み**: `settingSources: ['user', 'project']` でCLI同等の機能を実現 (line 297)
3. **CLI固有機能のほぼすべてを代替済み**: Slash commands, Skills, MCP serversすべて有効化済み
4. **既存のworkaroundが安定**: Issue #29対策 (ADR 001) は本番環境で安定して動作中
5. **CLI既知問題がより深刻**: JSON truncation, missing final result, resume bugはworkaround困難
6. **依存管理の信頼性が重要**: npm package管理はCI/CDでの再現性を保証
7. **パフォーマンスが重要**: Neovim統合ではレイテンシが重要
8. **vibing.nvim独自機能の優位性**: CLIにない機能を多数実装済み

### Future Re-evaluation Criteria

以下の条件が満たされた場合、この決定を再評価する必要があります：

1. **CLI既知問題がすべて解決** AND **Agent SDK Issue #29が悪化**
2. **CLIがカスタム権限制御をサポート** (hook機構など)
3. **Agent SDKが非推奨化**

それ以外の場合、Agent SDK実装を継続します。

### Acknowledgments

この調査は、Claude Code公式ドキュメント、既存のADR (001, 002)、および現在の実装 (`bin/agent-wrapper.mjs`) の詳細な分析に基づいています。

---

**最終判断**: Agent SDK (`@anthropic-ai/claude-agent-sdk`) の継続使用を推奨します。
