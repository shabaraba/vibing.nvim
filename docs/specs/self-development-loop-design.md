# Self-Development Loop - Detailed Design Specification

## Overview

vibing.nvim が自分自身を修正・テスト・デバッグする「自己開発ループ」機能の詳細設計。

**関連ドキュメント**:

- [ADR 007: Self-Development Loop with Nested Neovim Testing](../adr/007-self-development-loop.md)
- [Nested Neovim Feasibility Research](./nested-nvim-research.md) - ネストした Neovim の動作検証

## Goals

1. Claude が vibing.nvim のコードを安全に修正できる
2. 修正後のコードを自動的にテストできる
3. テスト失敗時に自動ロールバックできる
4. 環境非依存で動作する

## Non-Goals

1. 完全な CI/CD パイプライン（あくまで開発中の動作確認）
2. 複雑な統合テスト（基本的な動作確認のみ）
3. パフォーマンステスト

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Main Neovim Process (port 9876)                             │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ vibing chat (Claude executing)                         │ │
│  │  - User message: "Fix bug X"                           │ │
│  │  - Claude: Read code, Edit code                        │ │
│  │  - Claude: MCP call nvim_reload_with_nested_test()    │ │
│  └────────────────────────────────────────────────────────┘ │
│                            │                                 │
│                            ▼                                 │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ lua/vibing/init.lua                                    │ │
│  │  reload_with_nested_test()                             │ │
│  └────────────────────────────────────────────────────────┘ │
│                            │                                 │
│         ┌──────────────────┴──────────────────┐             │
│         ▼                                     ▼             │
│  ┌─────────────────┐                ┌──────────────────┐   │
│  │ git_helper.lua  │                │ nested_test.lua  │   │
│  │ create_backup() │                │ spawn_test_nvim()│   │
│  └─────────────────┘                └──────────────────┘   │
│         │                                     │             │
│         ▼                                     ▼             │
│  ┌─────────────────┐                ┌──────────────────┐   │
│  │ Git Repository  │                │ :terminal buffer │   │
│  │ - WIP commit    │                │ - Nested nvim    │   │
│  └─────────────────┘                └──────────────────┘   │
│                                               │             │
│                                               ▼             │
│                                    ┌────────────────────┐   │
│                                    │ Nested Neovim      │   │
│                                    │ (port 9877)        │   │
│                                    │ - Run tests        │   │
│                                    │ - Write results    │   │
│                                    └────────────────────┘   │
│                                               │             │
└───────────────────────────────────────────────┼─────────────┘
                                                ▼
                                    ┌────────────────────┐
                                    │ Shared File        │
                                    │ vibing_reload_     │
                                    │ test.json          │
                                    └────────────────────┘
                                                ▲
                                                │
                                    ┌───────────┴────────┐
                                    │ MCP Tool           │
                                    │ (Polling)          │
                                    └────────────────────┘
```

## Component Specifications

### 1. Git Helper Module

**File**: `lua/vibing/core/utils/git_helper.lua`

#### API

```lua
---@class GitBackupInfo
---@field commit_hash string WIP コミットのハッシュ
---@field branch_name string|nil ブランチ名（オプション）
---@field timestamp number バックアップ作成時刻

---WIP コミットを作成してバックアップを返す
---@return GitBackupInfo|nil backup バックアップ情報、失敗時は nil
---@return string|nil error エラーメッセージ
function M.create_backup()

---バックアップからロールバックする
---@param backup GitBackupInfo バックアップ情報
---@return boolean success
---@return string|nil error エラーメッセージ
function M.rollback(backup)

---バックアップを確定（WIP コミットを残す）
---@param backup GitBackupInfo バックアップ情報
---@return boolean success
function M.commit_backup(backup)
```

#### Implementation Details

**create_backup()**:

```lua
function M.create_backup()
  -- 1. 変更があるか確認
  local status_result = vim.system({ "git", "status", "--porcelain" }):wait()
  if status_result.code ~= 0 then
    return nil, "Git status failed"
  end

  if status_result.stdout == "" then
    return nil, "No changes to backup"
  end

  -- 2. すべての変更を add
  local add_result = vim.system({ "git", "add", "-A" }):wait()
  if add_result.code ~= 0 then
    return nil, "Git add failed"
  end

  -- 3. WIP コミット作成
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local commit_msg = string.format("WIP: vibing.nvim reload test - %s", timestamp)

  local commit_result = vim.system({
    "git", "commit", "-m", commit_msg
  }):wait()

  if commit_result.code ~= 0 then
    return nil, "Git commit failed"
  end

  -- 4. コミットハッシュを取得
  local hash_result = vim.system({ "git", "rev-parse", "HEAD" }):wait()
  local commit_hash = hash_result.stdout:gsub("\n", "")

  return {
    commit_hash = commit_hash,
    branch_name = nil,
    timestamp = os.time(),
  }
end
```

**rollback()**:

```lua
function M.rollback(backup)
  if not backup or not backup.commit_hash then
    return false, "Invalid backup info"
  end

  -- soft reset で HEAD を1つ戻す（変更はワークツリーに残る）
  local reset_result = vim.system({
    "git", "reset", "--soft", "HEAD~1"
  }):wait()

  if reset_result.code ~= 0 then
    return false, "Git reset failed"
  end

  -- 変更を破棄
  local checkout_result = vim.system({
    "git", "checkout", "."
  }):wait()

  if checkout_result.code ~= 0 then
    return false, "Git checkout failed"
  end

  return true
end
```

**commit_backup()**:

```lua
function M.commit_backup(backup)
  -- WIP コミットメッセージを変更
  local amend_result = vim.system({
    "git", "commit", "--amend", "-m",
    "feat: vibing.nvim self-development changes"
  }):wait()

  return amend_result.code == 0
end
```

### 2. Nested Test Module

**File**: `lua/vibing/dev/nested_test.lua`

#### API

```lua
---@class NestedTestInfo
---@field term_bufnr number ターミナルバッファ番号
---@field term_chan number チャンネル ID
---@field test_result_file string 結果ファイルパス
---@field test_script string テストスクリプトパス

---@class TestResult
---@field status "starting"|"testing"|"passed"|"failed" テスト状態
---@field timestamp number タイムスタンプ
---@field tests TestCase[] テストケース配列

---@class TestCase
---@field name string テスト名
---@field success boolean 成功/失敗
---@field message string メッセージ

---ネストした Neovim でテストを起動
---@return NestedTestInfo info
function M.spawn_test_nvim()

---テスト結果を読み取る
---@return TestResult|nil result
function M.read_test_result()

---ネストした Neovim を閉じる
---@param term_chan number チャンネル ID
function M.close_test_nvim(term_chan)
```

#### Implementation Details

**spawn_test_nvim()**:

```lua
function M.spawn_test_nvim()
  local test_result_file = vim.fn.stdpath("data") .. "/vibing_reload_test.json"

  -- 初期状態を書き込み
  vim.fn.writefile({
    vim.json.encode({
      status = "starting",
      timestamp = os.time(),
      tests = {},
    })
  }, test_result_file)

  -- テストスクリプト生成
  local test_script = M._generate_test_script(test_result_file)
  local test_script_path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(test_script, test_script_path)

  -- Terminal を開く
  vim.cmd("split")
  vim.cmd("terminal")

  local term_bufnr = vim.api.nvim_get_current_buf()
  local term_chan = vim.api.nvim_buf_get_var(term_bufnr, "terminal_job_id")

  -- Nested nvim を起動
  local cmd = string.format(
    "nvim -u %s -c 'luafile %s'\n",
    vim.env.MYVIMRC or "NONE",
    test_script_path
  )

  vim.fn.chansend(term_chan, cmd)

  return {
    term_bufnr = term_bufnr,
    term_chan = term_chan,
    test_result_file = test_result_file,
    test_script = test_script_path,
  }
end
```

**\_generate_test_script()**:

```lua
function M._generate_test_script(test_result_file)
  return {
    '-- Auto-generated test script for vibing.nvim reload',
    'local result = { status = "testing", timestamp = os.time(), tests = {} }',
    'local test_file = "' .. test_result_file .. '"',
    '',
    '-- Helper: report test result',
    'local function report(name, success, message)',
    '  table.insert(result.tests, {',
    '    name = name,',
    '    success = success,',
    '    message = message or "",',
    '  })',
    '  vim.fn.writefile({ vim.json.encode(result) }, test_file)',
    'end',
    '',
    '-- Test 1: Load vibing.nvim',
    'local ok, err = pcall(function()',
    '  require("vibing").setup({',
    '    mcp = { enabled = true, rpc_port = 9877 },',
    '    chat = { window = { position = "current" } },',
    '  })',
    'end)',
    '',
    'report("load_vibing", ok, ok and "Module loaded successfully" or tostring(err))',
    '',
    'if not ok then',
    '  result.status = "failed"',
    '  vim.fn.writefile({ vim.json.encode(result) }, test_file)',
    '  vim.cmd("qall!")',
    '  return',
    'end',
    '',
    '-- Test 2: Open chat',
    'vim.schedule(function()',
    '  local ok2, err2 = pcall(function()',
    '    vim.cmd("VibingChat")',
    '  end)',
    '  ',
    '  report("open_chat", ok2, ok2 and "Chat window opened" or tostring(err2))',
    '  ',
    '  -- Test 3: Check buffer',
    '  if ok2 then',
    '    local buftype = vim.bo.buftype',
    '    local filetype = vim.bo.filetype',
    '    local is_valid = (filetype == "vibing")',
    '    report("buffer_check", is_valid,',
    '           is_valid and "Buffer configured correctly" or',
    '           string.format("Invalid buffer: ft=%s bt=%s", filetype, buftype))',
    '  end',
    '  ',
    '  -- Finalize',
    '  local all_passed = true',
    '  for _, test in ipairs(result.tests) do',
    '    if not test.success then',
    '      all_passed = false',
    '      break',
    '    end',
    '  end',
    '  ',
    '  result.status = all_passed and "passed" or "failed"',
    '  vim.fn.writefile({ vim.json.encode(result) }, test_file)',
    '  ',
    '  -- Keep nvim open for inspection (MCP will close it)',
    'end)',
  }
end
```

**read_test_result()**:

```lua
function M.read_test_result()
  local test_file = vim.fn.stdpath("data") .. "/vibing_reload_test.json"

  if vim.fn.filereadable(test_file) == 0 then
    return nil
  end

  local content = vim.fn.readfile(test_file)
  if not content or #content == 0 then
    return nil
  end

  local ok, result = pcall(vim.json.decode, table.concat(content, "\n"))
  if not ok then
    return nil
  end

  return result
end
```

**close_test_nvim()**:

```lua
function M.close_test_nvim(term_chan)
  if not term_chan then
    return
  end

  -- Send :qa! to nested nvim
  vim.fn.chansend(term_chan, { ":qa!\n" })

  -- Wait a bit for process to exit
  vim.defer_fn(function()
    -- Close terminal buffer if it still exists
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
        if buftype == "terminal" then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end
  end, 500)
end
```

### 3. Main Entry Point

**File**: `lua/vibing/init.lua`

#### API

```lua
---@class ReloadResult
---@field success boolean
---@field test_info NestedTestInfo|nil
---@field backup GitBackupInfo|nil
---@field error string|nil

---ネストした Neovim でテストを実行しながら reload
---@return ReloadResult
function M.reload_with_nested_test()
```

#### Implementation

```lua
function M.reload_with_nested_test()
  local notify = require("vibing.infrastructure.notify")
  local git_helper = require("vibing.core.utils.git_helper")
  local nested_test = require("vibing.dev.nested_test")

  -- 1. Git バックアップ作成
  local backup, err = git_helper.create_backup()
  if not backup then
    notify.error("Failed to create backup: " .. (err or "unknown error"))
    return {
      success = false,
      error = err,
    }
  end

  notify.info("Backup created: " .. backup.commit_hash:sub(1, 7))

  -- 2. Nested nvim でテスト起動
  local test_info = nested_test.spawn_test_nvim()

  notify.info("Test Neovim spawned. Waiting for results...")

  return {
    success = true,
    test_info = test_info,
    backup = backup,
  }
end
```

### 4. MCP Tool

**File**: `mcp-server/src/tools/reload.ts`

#### Interface

```typescript
interface ReloadOptions {
  timeout_seconds?: number; // Default: 30
}

interface ReloadResult {
  success: boolean;
  status: 'passed' | 'failed' | 'timeout';
  tests: TestCase[];
  error?: string;
  backup?: GitBackupInfo;
}
```

#### Implementation

```typescript
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { z } from 'zod';

export function registerReloadTool(server: Server, rpcClient: RPCClient) {
  server.tool(
    'nvim_reload_with_nested_test',
    'Reload vibing.nvim and test in nested Neovim process',
    {
      timeout_seconds: z
        .number()
        .optional()
        .default(30)
        .describe('Maximum time to wait for test results (seconds)'),
    },
    async (args) => {
      const timeoutMs = args.timeout_seconds * 1000;

      try {
        // 1. Start nested test
        const reloadResult = await rpcClient.call('nvim_exec_lua', [
          'return require("vibing").reload_with_nested_test()',
          [],
        ]);

        if (!reloadResult.success) {
          return {
            content: [
              {
                type: 'text',
                text: `Failed to start test: ${reloadResult.error}`,
              },
            ],
          };
        }

        const testFile = reloadResult.test_info.test_result_file;
        const backup = reloadResult.backup;

        // 2. Poll for test results
        const startTime = Date.now();
        let lastStatus = 'starting';

        while (Date.now() - startTime < timeoutMs) {
          await new Promise((resolve) => setTimeout(resolve, 1000));

          const result = await rpcClient.call('nvim_exec_lua', [
            'return require("vibing.dev.nested_test").read_test_result()',
            [],
          ]);

          if (!result) {
            continue;
          }

          // Update status
          if (result.status !== lastStatus) {
            lastStatus = result.status;
            console.log(`Test status: ${result.status}`);
          }

          // Check if done
          if (result.status === 'passed' || result.status === 'failed') {
            // 3. Handle result
            if (result.status === 'passed') {
              // Success: commit backup
              await rpcClient.call('nvim_exec_lua', [
                `return require("vibing.core.utils.git_helper").commit_backup(${JSON.stringify(backup)})`,
                [],
              ]);
            } else {
              // Failed: rollback
              await rpcClient.call('nvim_exec_lua', [
                `return require("vibing.core.utils.git_helper").rollback(${JSON.stringify(backup)})`,
                [],
              ]);
            }

            // 4. Close nested nvim
            await rpcClient.call('nvim_exec_lua', [
              `require("vibing.dev.nested_test").close_test_nvim(${reloadResult.test_info.term_chan})`,
              [],
            ]);

            // 5. Return result
            return {
              content: [
                {
                  type: 'text',
                  text: formatTestResult(result),
                },
              ],
            };
          }
        }

        // Timeout
        await rpcClient.call('nvim_exec_lua', [
          `require("vibing.dev.nested_test").close_test_nvim(${reloadResult.test_info.term_chan})`,
          [],
        ]);

        return {
          content: [
            {
              type: 'text',
              text: `Test timeout after ${args.timeout_seconds} seconds. Status: ${lastStatus}`,
            },
          ],
        };
      } catch (error) {
        return {
          content: [
            {
              type: 'text',
              text: `Error during reload: ${error.message}`,
            },
          ],
        };
      }
    }
  );
}

function formatTestResult(result: any): string {
  const lines = [
    `Test Status: ${result.status}`,
    `Timestamp: ${new Date(result.timestamp * 1000).toISOString()}`,
    '',
    'Test Results:',
  ];

  for (const test of result.tests) {
    const icon = test.success ? '✅' : '❌';
    lines.push(`  ${icon} ${test.name}: ${test.message}`);
  }

  return lines.join('\n');
}
```

## Usage Workflow

### Normal Flow (Success)

```
1. User: "Fix bug in chat buffer"

2. Claude:
   - Read lua/vibing/presentation/chat/buffer.lua
   - Edit: Fix the bug

3. Claude:
   - use_mcp_tool('vibing-nvim', 'nvim_reload_with_nested_test', {
       timeout_seconds: 30
     })

4. vibing.nvim:
   - Git: create backup (commit abc123)
   - Terminal: spawn nested nvim on port 9877
   - Nested nvim: run tests
   - File: write results to vibing_reload_test.json

5. MCP Tool:
   - Poll file every 1 second
   - Detect status: "passed"
   - Git: commit backup
   - Terminal: close nested nvim
   - Return: test results

6. Claude:
   "✅ Tests passed! Bug fix verified:
    - load_vibing: ✅ Module loaded successfully
    - open_chat: ✅ Chat window opened
    - buffer_check: ✅ Buffer configured correctly"
```

### Error Flow (Test Failed)

```
1-3. [Same as above]

4. vibing.nvim:
   - Git: create backup (commit abc123)
   - Terminal: spawn nested nvim
   - Nested nvim: ERROR in setup()
   - File: write { status: "failed", tests: [...] }

5. MCP Tool:
   - Poll file
   - Detect status: "failed"
   - Git: rollback (reset HEAD~1, checkout .)
   - Terminal: close nested nvim
   - Return: error details

6. Claude:
   "❌ Tests failed, changes rolled back:
    - load_vibing: ❌ Module load failed: syntax error at line 42

    Let me fix the syntax error and try again."
```

### Timeout Flow

```
1-4. [Same as above]

5. MCP Tool:
   - Poll file for 30 seconds
   - Status remains "testing"
   - Timeout
   - Terminal: force close nested nvim
   - Return: timeout message

6. Claude:
   "⚠️ Test timeout after 30 seconds.
    The nested Neovim may have hung.
    Please check the terminal buffer manually."
```

## Error Handling

### Error Categories

1. **Git Errors**
   - No changes to backup
   - Commit failed
   - Reset/checkout failed

2. **Nested Neovim Errors**
   - Failed to spawn terminal
   - chansend failed
   - Nested nvim crashed

3. **Test Errors**
   - Module load failed
   - Setup failed
   - Chat open failed

4. **File I/O Errors**
   - Cannot write test result
   - Cannot read test result
   - JSON parse error

### Error Recovery

| Error                    | Recovery                             |
| ------------------------ | ------------------------------------ |
| Git backup failed        | Abort, warn user                     |
| Nested nvim spawn failed | Abort, rollback not needed           |
| Test failed              | Auto rollback                        |
| Timeout                  | Force close, manual inspection       |
| MCP connection lost      | Tests continue, results not reported |

## Testing Strategy

### Unit Tests

**File**: `tests/vibing/dev/git_helper_spec.lua`

```lua
describe("git_helper", function()
  it("creates backup with WIP commit", function() end)
  it("rollbacks changes correctly", function() end)
  it("commits backup with proper message", function() end)
  it("handles no changes gracefully", function() end)
end)
```

**File**: `tests/vibing/dev/nested_test_spec.lua`

```lua
describe("nested_test", function()
  it("generates valid test script", function() end)
  it("reads test result correctly", function() end)
  it("handles missing file gracefully", function() end)
end)
```

### Integration Tests (Manual)

1. **Basic reload test**
   - Make simple change
   - Run reload
   - Verify test passes

2. **Syntax error test**
   - Introduce Lua syntax error
   - Run reload
   - Verify rollback works

3. **Runtime error test**
   - Introduce runtime error in setup
   - Run reload
   - Verify test fails and rolls back

4. **Timeout test**
   - Create infinite loop in test
   - Run reload with short timeout
   - Verify timeout handling

## Security Considerations

1. **File Permissions**
   - Test result file in user's stdpath (secure)
   - Test script in tempname (auto-cleanup)

2. **Git Operations**
   - Limited to current repository
   - No remote push/pull
   - WIP commits are local only

3. **Terminal Access**
   - Nested nvim has same permissions as parent
   - No privilege escalation

4. **Resource Limits**
   - Timeout prevents infinite loops
   - Single nested nvim at a time
   - Auto-cleanup on exit

## Performance Considerations

- **Nested nvim startup**: ~2-3 seconds
- **Test execution**: ~1-2 seconds
- **Polling overhead**: 1 second interval
- **Total time**: ~5-10 seconds per reload

## Future Enhancements

1. **More comprehensive tests**
   - LSP integration test
   - MCP tool test
   - Inline action test

2. **Parallel testing**
   - Run multiple test scenarios
   - Aggregate results

3. **Test coverage reporting**
   - Track which components were tested
   - Identify untested code paths

4. **Visual feedback**
   - Progress bar in terminal
   - Real-time test output

5. **Snapshot testing**
   - Compare output before/after
   - Detect regressions

## References

- [ADR 007: Self-Development Loop](../adr/007-self-development-loop.md)
- [Neovim Terminal Documentation](https://neovim.io/doc/user/nvim_terminal_emulator.html)
- [MCP Server Development Guide](../../mcp-server/README.md)

## Changelog

- 2025-01-11: Initial design specification
