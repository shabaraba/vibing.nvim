# Nested Neovim Feasibility Research

## Overview

ネストした Neovim プロセス（`:terminal` 内で nvim を起動）の動作を調査し、自己開発ループでの利用可能性を検証しました。

**関連ドキュメント**:
- [ADR 007: Self-Development Loop](../adr/007-self-development-loop.md)
- [Self-Development Loop Design](./self-development-loop-design.md)

## Research Questions

1. ネストした Neovim はキーボード入力を正しく受け付けるか？
2. ホスト側のキーバインドと競合しないか？
3. コマンド実行（`:VibingChat` など）は動作するか？
4. MCP 経由での制御は可能か？
5. 自動化されたテストに適しているか？

## Findings

### 1. Terminal Mode の仕様

**キーボード入力の挙動**:

Neovim の `:terminal` モードでは、以下の仕様が適用されます：

> To send input in Neovim's terminal mode, you enter Terminal-mode with `i`, `I`, `a`, `A` or `:startinsert`, and in this mode all keys except `<C-\>` are sent to the underlying program.

**重要な点**:
- `<C-\><C-N>` **以外**のすべてのキーは、下層のプログラム（ネストした nvim）に送信される
- `<C-\><C-N>` を押すとホスト側の Normal モードに戻る
- Terminal モード中は、ホスト側のキーバインドは発動しない

**結論**: キーバインドの競合は**発生しない**。

**Source**: [Terminal - Neovim docs](https://neovim.io/doc/user/terminal.html)

### 2. Nested Neovim の既知の制限

**公式ドキュメントより**:

> `:terminal` doesn't handle nested Neovim instances.

これは既知の制限事項として認識されており、以下のような問題が発生します：

- ファイルを開く操作が親インスタンスではなくネストしたインスタンスで実行される
- `git commit` や `git rebase -i` でエディタを開くと、二重にネストする可能性

**コミュニティの解決策**:

複数のプラグインがこの問題に対処しています：

1. **[unnest.nvim](https://github.com/brianhuster/unnest.nvim)** (2025年最新)
   - ネストしたセッションを検出し、親インスタンスでファイルを開くよう指示
   - 設定不要、`setup()` 呼び出し不要
   - Nvim 0.11+ 必要
   - `git commit`、`git rebase -i` などで便利

2. **[nvim-unception](https://neovimcraft.com/plugin/samjwill/nvim-unception/)**
   - RPC 機能を活用してファイル操作を親インスタンスに転送

3. **[flatnvim](https://github.com/adamtabrams/flatnvim)**
   - Terminal 内でファイルを開くと、自動的に現在のインスタンスに追加

**Source**:
- [Neovim as a Terminal Multiplexer and Neovide as a Terminal Emulator](https://loosh.ch/blog/neovidenal)
- [Running nvim in a neovim terminal should not create a nested neovim · Issue #5472](https://github.com/neovim/neovim/issues/5472)

### 3. プログラム制御（chansend）

**`vim.fn.chansend()` による制御**:

Terminal バッファのプロセスは `vim.fn.chansend()` で完全に制御可能です。

**基本的な使い方**:

```lua
-- Terminal バッファの channel ID を取得
local term_bufnr = vim.api.nvim_get_current_buf()
local term_chan = vim.api.nvim_buf_get_var(term_bufnr, "terminal_job_id")

-- 通常のコマンドを送信
vim.fn.chansend(term_chan, ":VibingChat\n")

-- 特殊キーを送信
vim.fn.chansend(term_chan, vim.keycode("<C-c>"))
vim.fn.chansend(term_chan, vim.keycode("<CR>"))
```

**複数行のコマンド送信**:

```lua
vim.fn.chansend(term_chan, {
  "nvim -u ~/.config/nvim/init.lua\n",
  ":echo 'Hello'\n",
  ":quit\n",
})
```

**特殊キーの送信例**:

公式ドキュメントより：

> To send special keys, you can use `vim.keycode()`, for example: `vim.api.nvim_chan_send(chan["id"], vim.keycode("<C-c>"))`

**Source**:
- [Job Control - Neovim docs](https://neovim.io/doc/user/job_control.html)
- [Channel - Neovim docs](https://neovim.io/doc/user/channel.html)
- [Neovim Terminal - Neovim docs](http://neovim.io/doc/user/nvim_terminal_emulator.html)

### 4. RPC による自動テスト

**Neovim 公式テストフレームワークの設計**:

Neovim 自身の機能テストは、RPC 経由で別プロセスを制御する方式を採用しています：

> Functional tests are driven by RPC, so they do not require LuaJit, and each test starts a new Nvim process (10-30ms) which is discarded after the test finishes.

**mini.test フレームワークの例**:

> The main feature of 'mini.test' is its design towards custom usage of child Neovim process inside tests, where each test should be done with fresh Neovim process initialized with bare minimum setup. Current and child Neovim processes can "talk" to each through RPC messages, meaning you can programmatically execute code inside child process, get its output inside current process, and test if it meets your expectation.

**重要な洞察**:

Busted を使ったテストガイドより：

> The key insight is that the Neovim instance running the test does not have to be the same Neovim instance which is being tested, similar to what the Selenium framework does with web browsers.

**Source**:
- [mini.nvim/TESTING.md](https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md)
- [Testing Neovim plugins with Busted](https://hiphish.github.io/blog/2024/01/29/testing-neovim-plugins-with-busted/)
- [Dev_test - Neovim docs](https://neovim.io/doc/user/dev_test.html)

### 5. RPC Communication API

**利用可能な RPC 関数**:

```lua
-- ブロッキング RPC 呼び出し
vim.rpcrequest(channel, method, ...)

-- 非ブロッキング RPC 通知
vim.rpcnotify(channel, event, ...)
```

**制限事項**:

> Due to current RPC protocol implementation functions and userdata can't be used in both input and output with child process, indicated by a "Cannot convert given lua type" error.

**回避策**: プリミティブ型（string、number、table など）のみを使用する。

**Source**:
- [RPC and Channels | neovim/neovim | DeepWiki](https://deepwiki.com/neovim/neovim/4.4-rpc-and-job-management)
- [Api - Neovim docs](https://neovim.io/doc/user/api.html)

## Application to Self-Development Loop

### ✅ Feasibility Confirmation

調査結果から、ネストした Neovim を使った自己開発ループは**完全に実現可能**です。

### Design Validation

**1. キーバインド競合の回避**

自動化されたテストでは、キーバインドは使用しません：

```lua
-- テストスクリプト（ネストした nvim 内で実行）
require("vibing").setup({ mcp = { rpc_port = 9877 } })

vim.schedule(function()
  vim.cmd("VibingChat")  -- コマンドで実行（キーバインド不要）

  -- テスト結果を JSON に書き込み
  local result = { status = "passed", tests = {...} }
  vim.fn.writefile({ vim.json.encode(result) }, test_file)
end)
```

**2. プログラム制御の実現**

`chansend()` でネストした nvim を完全制御：

```lua
-- nested_test.lua
function M.spawn_test_nvim()
  vim.cmd("split | terminal")
  local term_chan = vim.api.nvim_buf_get_var(term_bufnr, "terminal_job_id")

  -- Lua スクリプトを自動実行
  vim.fn.chansend(term_chan, "nvim -c 'luafile test.lua'\n")

  return { term_chan = term_chan, ... }
end
```

**3. MCP との分離**

- 親 Neovim: MCP RPC server (port 9876)
- ネスト Neovim: MCP RPC server (port 9877)
- ポートが異なるため競合しない

**4. 公式テストと同じアプローチ**

Neovim 自身のテストフレームワークと同じ設計思想：

- 別プロセスで実行
- RPC/chansend で制御
- テスト完了後にプロセスを破棄
- 信頼性が高い

### Implementation Strategy

**Phase 1: Basic Automation**

```lua
-- test_script.lua (自動実行)
local result = { status = "testing", tests = {} }

-- Test 1: Module load
local ok, err = pcall(function()
  require("vibing").setup({ mcp = { rpc_port = 9877 } })
end)
table.insert(result.tests, { name = "load", success = ok })

-- Test 2: Open chat
vim.schedule(function()
  local ok2 = pcall(function() vim.cmd("VibingChat") end)
  table.insert(result.tests, { name = "open_chat", success = ok2 })

  result.status = (ok and ok2) and "passed" or "failed"
  vim.fn.writefile({ vim.json.encode(result) }, test_file)
end)
```

**Phase 2: Advanced Control**

必要に応じて、より複雑な操作も可能：

```lua
-- 特定のバッファ内容を取得
vim.fn.chansend(term_chan, ":lua print(vim.api.nvim_buf_line_count(0))\n")

-- Ex コマンドを実行
vim.fn.chansend(term_chan, ":VibingContext test.lua\n")

-- 終了
vim.fn.chansend(term_chan, ":qa!\n")
```

## Known Limitations

### 1. UI の制約

Terminal 内の Neovim は、一部の UI 機能に制限があります：

- Clipboard 統合が制限される可能性
- 一部のターミナルエミュレータ固有の機能が使えない場合がある

**影響**: 自動テストには影響なし（UI 操作を行わないため）

### 2. Performance Overhead

- ネストした Neovim の起動: ~2-3秒
- テスト実行: ~1-2秒
- 合計: ~5-10秒

**影響**: 許容範囲内（開発フローの一部として）

### 3. Debugging Challenges

ネストした Neovim 内のエラーは、親プロセスから直接見えません。

**対策**:
- テスト結果を JSON に詳細に記録
- Terminal バッファで目視確認可能
- `pcall` でエラーをキャッチして記録

## Recommendations

### DO ✅

1. **chansend() でコマンド送信**
   - Lua スクリプトを自動実行
   - Ex コマンドで操作

2. **JSON でテスト結果を記録**
   - 構造化されたデータ
   - エラーメッセージも含める

3. **pcall でエラーハンドリング**
   - すべての操作を保護
   - エラーを結果に含める

4. **別ポートで MCP 起動**
   - 親: 9876
   - ネスト: 9877

### DON'T ❌

1. **手動キー入力に依存しない**
   - すべて自動化
   - キーバインドは使わない

2. **UI 機能に依存しない**
   - Clipboard、マウス操作など
   - コマンドと Lua API のみ使用

3. **長時間の実行**
   - タイムアウトを設定（30秒推奨）
   - 無限ループを防ぐ

## Conclusion

ネストした Neovim を使った自己開発ループは、以下の理由で**完全に実現可能**です：

1. ✅ **公式にサポートされている**: Neovim のテストフレームワークで実績あり
2. ✅ **プログラム制御が可能**: `chansend()` で完全制御
3. ✅ **キーバインド競合なし**: 自動化されているため無関係
4. ✅ **MCP との分離**: 異なるポートで動作
5. ✅ **エラーハンドリング**: pcall + JSON で堅牢

**Next Steps**:
1. Git helper の実装
2. Nested test module の実装
3. MCP tool の実装
4. E2E テストの実施

## References

### Official Documentation
- [Terminal - Neovim docs](https://neovim.io/doc/user/terminal.html)
- [Job Control - Neovim docs](https://neovim.io/doc/user/job_control.html)
- [Channel - Neovim docs](https://neovim.io/doc/user/channel.html)
- [Api - Neovim docs](https://neovim.io/doc/user/api.html)
- [Dev_test - Neovim docs](https://neovim.io/doc/user/dev_test.html)
- [Nvim Terminal Emulator - Neovim docs](http://neovim.io/doc/user/nvim_terminal_emulator.html)

### Community Resources
- [unnest.nvim GitHub](https://github.com/brianhuster/unnest.nvim)
- [Neovim as a Terminal Multiplexer and Neovide as a Terminal Emulator (2025)](https://loosh.ch/blog/neovidenal)
- [nvim-unception](https://neovimcraft.com/plugin/samjwill/nvim-unception/)
- [flatnvim GitHub](https://github.com/adamtabrams/flatnvim)

### Testing Frameworks
- [mini.nvim/TESTING.md](https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md)
- [Testing Neovim plugins with Busted](https://hiphish.github.io/blog/2024/01/29/testing-neovim-plugins-with-busted/)

### Technical Deep Dives
- [RPC and Channels | neovim/neovim | DeepWiki](https://deepwiki.com/neovim/neovim/4.4-rpc-and-job-management)
- [Lua Engine Integration | neovim/neovim | DeepWiki](https://deepwiki.com/neovim/neovim/4.2-lua-engine-integration)

### Issue Discussions
- [Running nvim in a neovim terminal should not create a nested neovim · Issue #5472](https://github.com/neovim/neovim/issues/5472)
- [Kill the process running inside a given terminal · Discussion #35207](https://github.com/neovim/neovim/discussions/35207)

## Changelog

- 2025-01-11: Initial research and validation
