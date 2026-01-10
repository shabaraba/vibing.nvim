# ADR 006: JavaScript-based Patch Storage Implementation

## Status

Proposed

## Context

### Problem: Race Condition in Current Patch Storage

Issue #281 comment #3731122580で指摘された通り、現在のpatch storage実装にはRace Conditionが存在します。

**現在の実装の問題点:**

1. **2重のvim.schedule()による遅延**
   - `stream_handler.lua:17`: stdout受信時に1回目
   - `event_processor.lua:24`: `on_tool_use`で2回目

2. **タイミングの問題**
   ```
   tool_use出力 → vim.schedule()×2 ⏱️⏱️
        ↓
   [Node.jsが独立して動作]
   git add/commit 実行・完了 ✅
        ↓
   on_tool_useがやっと実行 ⏰
   PatchStorage.save() → git diff
   ❌ 遅すぎ - commit済みで差分なし
   ```

3. **git diffベースの限界**
   - `git commit`後では差分が取れない
   - `git add`のタイミングも制御不可能
   - untrackedファイルの扱いが複雑

### 要件

1. **git操作に依存しない**: `git add`/`git commit`の有無に関わらずpatch生成
2. **新規ファイル対応**: untrackedファイルも含める
3. **セッション単位の差分**: 前回のチャットの変更は含めない
4. **確実性**: Race conditionの影響を受けない

## Decision

**JavaScript側でpatch生成を完結させる**アプローチを採用します。

### アーキテクチャ

```
┌─────────────────────────────────────────────────────────┐
│ Node.js Process (agent-wrapper.mjs)                      │
│                                                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │ Session State                                    │    │
│  │  - currentSessionModifiedFiles: Set<string>     │    │
│  │  - savedFileContents: Map<string, string|null>  │    │
│  └─────────────────────────────────────────────────┘    │
│                                                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │ Event Handler                                    │    │
│  │  tool_use検知                                     │    │
│  │    ↓                                             │    │
│  │  ファイルパス記録                                │    │
│  │    ↓                                             │    │
│  │  変更前内容保存（初回のみ）                      │    │
│  └─────────────────────────────────────────────────┘    │
│                                                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │ Patch Generator (result時)                       │    │
│  │  1. 各ファイルの差分計算                         │    │
│  │  2. untrackedファイルの検出                      │    │
│  │  3. unified diff形式で出力                       │    │
│  │  4. .vibing/patches/に保存                       │    │
│  └─────────────────────────────────────────────────┘    │
│                                                           │
└─────────────────────────────────────────────────────────┘
         │
         ↓ {"type": "patch_saved", "filename": "..."}
┌─────────────────────────────────────────────────────────┐
│ Neovim Process                                           │
│  - patch_filenameを受け取る                              │
│  - chatバッファに<!-- patch: ... -->を記録              │
└─────────────────────────────────────────────────────────┘
```

### 実装の詳細

#### 1. セッション状態管理

```javascript
// agent-wrapper.mjs
const currentSessionModifiedFiles = new Set();
const savedFileContents = new Map();

// tool_use検知時
if (block.type === 'tool_use') {
  const toolName = block.name;
  const toolInput = block.input || {};

  // Edit/Write
  if ((toolName === 'Edit' || toolName === 'Write') && toolInput.file_path) {
    const filePath = toolInput.file_path;

    // 初回のみ変更前内容を保存
    if (!savedFileContents.has(filePath)) {
      savedFileContents.set(filePath, readFileIfExists(filePath));
    }

    currentSessionModifiedFiles.add(filePath);
  }
}
```

#### 2. nvim_set_bufferの追跡

```javascript
// tool_result受信時
if (block.type === 'tool_result' && toolName === 'mcp__vibing-nvim__nvim_set_buffer') {
  const match = resultText.match(/Buffer updated successfully \(([^)]+)\)/);
  if (match) {
    const filePath = match[1];

    if (!savedFileContents.has(filePath)) {
      savedFileContents.set(filePath, readFileIfExists(filePath));
    }

    currentSessionModifiedFiles.add(filePath);
  }
}
```

#### 3. Patch生成（result時）

```javascript
// message.type === 'result'時
if (currentSessionModifiedFiles.size > 0) {
  const patch = await generateSessionPatch(
    Array.from(currentSessionModifiedFiles),
    savedFileContents,
    sessionId
  );

  if (patch) {
    const patchFilename = savePatchToFile(sessionId, patch);

    console.log(safeJsonStringify({
      type: 'patch_saved',
      filename: patchFilename
    }));
  }

  // セッション終了後にクリア
  currentSessionModifiedFiles.clear();
  savedFileContents.clear();
}
```

#### 4. Patch生成ロジック

```javascript
async function generateSessionPatch(files, savedContents, sessionId) {
  const patches = [];

  for (const file of files) {
    const normalizedPath = path.resolve(file);
    const currentContent = readFileIfExists(normalizedPath);
    const savedContent = savedContents.get(file);

    if (savedContent !== null && savedContent !== undefined) {
      // このセッションで変更したファイル
      // saved_contentと現在の内容の差分
      const diff = await generateUnifiedDiff(
        savedContent,
        currentContent,
        file
      );

      if (diff) {
        patches.push(diff);
      }
    } else {
      // 新規作成ファイル
      if (currentContent && !isGitTracked(normalizedPath)) {
        // untracked file: 全内容を新規ファイルとして出力
        const diff = generateNewFileDiff(file, currentContent);
        patches.push(diff);
      }
    }
  }

  return patches.join('\n');
}

function isGitTracked(filepath) {
  try {
    execSync(`git ls-files --error-unmatch ${filepath}`, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function generateNewFileDiff(filepath, content) {
  const lines = content.split('\n');
  const header = [
    `diff --git a/${filepath} b/${filepath}`,
    'new file',
    '--- /dev/null',
    `+++ b/${filepath}`,
    `@@ -0,0 +1,${lines.length} @@`
  ];

  const body = lines.map(line => '+' + line);

  return [...header, ...body].join('\n');
}
```

### Lua側の変更

```lua
-- lua/vibing/application/chat/send_message.lua

-- patch_savedイベントハンドラを追加
elseif msg.type == "patch_saved" then
  -- JavaScript側で既に保存済み
  -- filenameだけ受け取る
  vim.schedule(function()
    -- chatバッファに記録するだけ
    callbacks.append_chunk("\n<!-- patch: " .. msg.filename .. " -->\n")
  end)
```

## Consequences

### Positive

1. ✅ **Race conditionの完全解消**
   - JavaScript側で完結するため、vim.schedule()の遅延の影響なし

2. ✅ **git操作に依存しない**
   - `git add`/`git commit`の有無に関わらず動作

3. ✅ **正確なセッション単位の差分**
   - `savedFileContents` = ツール実行直前の状態
   - 前回のチャットの変更は含まれない

4. ✅ **untrackedファイル対応**
   - `isGitTracked()`で判定して新規ファイルとして扱う

5. ✅ **シンプルな実装**
   - gitコマンドに頼らず、ファイルI/Oだけで完結

### Negative

1. ⚠️ **メモリ使用量の増加**
   - 各ファイルの変更前内容をメモリに保持
   - 大きなファイルが多い場合は注意が必要

2. ⚠️ **Node.jsへの依存増加**
   - より多くのロジックがJavaScript側に移動
   - Lua側のコードは薄くなる

### Mitigation

**メモリ対策:**
- ファイルサイズの上限チェック（例: 1MB以上は保存しない）
- セッション終了時に確実にクリア

**テスト:**
- 新規ファイル作成のテストケース
- 大量ファイル編集のテストケース
- git操作の有無によるテストケース

## Implementation Plan

1. ✅ Race condition分析完了（`analysis-race-condition.md`）
2. ⏳ JavaScript側の状態管理実装
   - `currentSessionModifiedFiles`
   - `savedFileContents`
3. ⏳ Patch生成ロジック実装
   - `generateSessionPatch()`
   - `generateUnifiedDiff()`
   - `generateNewFileDiff()`
4. ⏳ Lua側イベントハンドラ追加
   - `patch_saved`イベント処理
5. ⏳ 既存コード削除
   - `lua/vibing/application/chat/send_message.lua`の`on_tool_use`ベースのpatch保存
   - `lua/vibing/infrastructure/storage/patch_storage.lua`の`generate_patch()`
6. ⏳ テスト
   - 新規ファイル作成
   - 既存ファイル編集
   - git add/commit有無
   - セッション間での差分

## References

- Issue: #281 comment #3731122580
- Analysis: `analysis-race-condition.md`
- Related: `docs/adr/002-concurrent-execution-support.md`
