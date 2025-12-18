# API Reference

このドキュメントは vibing.nvim の全 API の詳細なリファレンスです。

## 目次

- [Core API](#core-api)
- [Adapter API](#adapter-api)
- [Context API](#context-api)
- [Chat Buffer API](#chat-buffer-api)
- [Output Buffer API](#output-buffer-api)

## Core API

### `vibing.setup(opts)`

プラグインを初期化します。

**Parameters:**

- `opts` (`Vibing.Config?`): 設定オプション（省略可）

**Example:**

```lua
require("vibing").setup({
  adapter = "agent_sdk",
  agent = {
    mode = "command",
    model = "claude-sonnet-4-5",
  },
  chat = {
    position = "right",
    size = 80,
    auto_context = false,
  },
})
```

### `vibing.get_adapter()`

現在のアダプターを取得します。

**Returns:**

- `Vibing.Adapter?`: アダプターインスタンス（未初期化の場合はnil）

**Example:**

```lua
local adapter = require("vibing").get_adapter()
if adapter then
  local response = adapter:execute("Hello", {})
end
```

### `vibing.get_config()`

現在の設定を取得します。

**Returns:**

- `Vibing.Config`: 設定オブジェクト

**Example:**

```lua
local config = require("vibing").get_config()
print(config.adapter)  -- "agent_sdk"
```

## Adapter API

### Base Adapter Interface

全アダプターは以下のインターフェースを実装します。

#### `Adapter:new(config)`

アダプターインスタンスを生成します。

**Parameters:**

- `config` (`Vibing.Config`): プラグイン設定

**Returns:**

- `Vibing.Adapter`: 新しいアダプターインスタンス

#### `Adapter:execute(prompt, opts)`

プロンプトを実行して応答を取得します（非ストリーミング）。

**Parameters:**

- `prompt` (`string`): 送信するプロンプト
- `opts` (`Vibing.AdapterOpts`): 実行オプション

**Returns:**

- `Vibing.Response`: 応答オブジェクト
  - `content` (`string`): 応答テキスト
  - `error` (`string?`): エラーメッセージ（成功時はnil）

**Example:**

```lua
local adapter = require("vibing").get_adapter()
local response = adapter:execute("Explain Lua tables", {
  context = {"@file:init.lua"},
})
if response.error then
  print("Error: " .. response.error)
else
  print(response.content)
end
```

#### `Adapter:stream(prompt, opts, on_chunk, on_done)`

プロンプトを実行してストリーミング応答を受信します。

**Parameters:**

- `prompt` (`string`): 送信するプロンプト
- `opts` (`Vibing.AdapterOpts`): 実行オプション
- `on_chunk` (`fun(chunk: string)`): チャンク受信時のコールバック
- `on_done` (`fun(response: Vibing.Response)`): 完了時のコールバック

**Example:**

```lua
local adapter = require("vibing").get_adapter()
adapter:stream("Write hello world", {},
  function(chunk)
    print("Received: " .. chunk)
  end,
  function(response)
    if response.error then
      print("Error: " .. response.error)
    else
      print("Done!")
    end
  end
)
```

#### `Adapter:cancel()`

実行中のプロンプトをキャンセルします。

**Returns:**

- `boolean`: キャンセル成功時true

#### `Adapter:supports(feature)`

アダプターが特定の機能をサポートしているかチェックします。

**Parameters:**

- `feature` (`string`): 機能名
  - `"streaming"`: ストリーミング対応
  - `"tools"`: ツール指定対応
  - `"model_selection"`: モデル選択対応
  - `"context"`: コンテキスト渡し対応

**Returns:**

- `boolean`: サポートしている場合true

**Example:**

```lua
local adapter = require("vibing").get_adapter()
if adapter:supports("streaming") then
  -- ストリーミング処理
else
  -- 非ストリーミング処理
end
```

### Adapter Types

#### Agent SDK Adapter

Claude Agent SDK を使用するアダプター（推奨）。

**Configuration:**

```lua
{
  adapter = "agent_sdk",
  agent = {
    mode = "command",  -- または "agentic"
    model = "claude-sonnet-4-5",
  },
}
```

**Features:**

- ✅ Streaming
- ✅ Tools
- ✅ Model selection
- ✅ Context
- ✅ Session management

#### Claude CLI Adapter

公式 `claude` CLI を使用するアダプター。

**Configuration:**

```lua
{
  adapter = "claude",
  cli_path = "claude",  -- CLI のパス
}
```

**Features:**

- ✅ Streaming
- ✅ Tools
- ✅ Model selection
- ✅ Context
- ❌ Session management

#### Claude ACP Adapter

JSON-RPC プロトコルでclaude-code-acpと通信するアダプター。

**Configuration:**

```lua
{
  adapter = "claude_acp",
}
```

**Features:**

- ✅ Streaming
- ✅ Tools
- ❌ Model selection
- ✅ Context
- ✅ Session management

## Context API

### `Context.add(path?)`

手動でコンテキストを追加します。

**Parameters:**

- `path` (`string?`): ファイルパス（省略時は現在のバッファ）

**Example:**

```lua
local Context = require("vibing.context")
Context.add("lua/vibing/init.lua")
Context.add()  -- 現在のバッファを追加
```

### `Context.clear()`

全てのコンテキストをクリアします。

**Example:**

```lua
require("vibing.context").clear()
```

### `Context.get_all(auto_context)`

全コンテキストを取得します（自動 + 手動）。

**Parameters:**

- `auto_context` (`boolean`): 自動コンテキストを含めるか

**Returns:**

- `string[]`: コンテキスト配列（@file:path形式）

### `Context.get_selection()`

ビジュアル選択範囲のコンテキストを取得します。

**Returns:**

- `string?`: コンテキスト（@file:path:L10-L25形式）

## Chat Buffer API

### `ChatBuffer:new(config)`

チャットバッファインスタンスを生成します。

**Parameters:**

- `config` (`Vibing.ChatConfig`): チャット設定

**Returns:**

- `Vibing.ChatBuffer`: 新しいチャットバッファインスタンス

### `ChatBuffer:open()`

チャットウィンドウを開きます。

### `ChatBuffer:close()`

チャットウィンドウを閉じます。

### `ChatBuffer:is_open()`

チャットウィンドウが開いているかチェックします。

**Returns:**

- `boolean`: 開いている場合true

### `ChatBuffer:append_chunk(chunk)`

ストリーミングチャンクを追加します。

**Parameters:**

- `chunk` (`string`): 追加するテキスト

### `ChatBuffer:start_spinner()`

処理中スピナーを開始します。

### `ChatBuffer:stop_spinner()`

処理中スピナーを停止します。

### `ChatBuffer:save()`

チャットをファイルに保存します。

**Returns:**

- `string?`: 保存したファイルパス（失敗時はnil）

## Output Buffer API

### `OutputBuffer:new(title)`

出力バッファインスタンスを生成します。

**Parameters:**

- `title` (`string`): バッファタイトル

**Returns:**

- `Vibing.OutputBuffer`: 新しい出力バッファインスタンス

### `OutputBuffer:open()`

出力ウィンドウを開きます。

### `OutputBuffer:close()`

出力ウィンドウを閉じます。

### `OutputBuffer:is_open()`

出力ウィンドウが開いているかチェックします。

**Returns:**

- `boolean`: 開いている場合true

### `OutputBuffer:set_content(lines)`

バッファの内容を設定します。

**Parameters:**

- `lines` (`string[]`): 設定する行の配列

### `OutputBuffer:append_chunk(chunk)`

ストリーミングチャンクを追加します。

**Parameters:**

- `chunk` (`string`): 追加するテキスト

### `OutputBuffer:show_error(error_message)`

エラーメッセージを表示します。

**Parameters:**

- `error_message` (`string`): エラーメッセージ

## Types

### `Vibing.Config`

```lua
---@class Vibing.Config
---@field adapter string アダプター名（"agent_sdk", "claude", "claude_acp"）
---@field cli_path string Claude CLI パス
---@field agent Vibing.AgentConfig Agent SDK設定
---@field chat Vibing.ChatConfig チャット設定
---@field inline Vibing.InlineConfig インラインアクション設定
---@field keymaps Vibing.KeymapConfig キーマップ設定
---@field permissions Vibing.PermissionsConfig 権限設定
---@field remote Vibing.RemoteConfig リモート制御設定
```

### `Vibing.AdapterOpts`

```lua
---@class Vibing.AdapterOpts
---@field streaming boolean ストリーミング有効化
---@field tools string[] 使用するツール名の配列
---@field model string モデル名
---@field context string[] コンテキストファイル（@file:path形式）
```

### `Vibing.Response`

```lua
---@class Vibing.Response
---@field content string 応答テキスト
---@field error string? エラーメッセージ（成功時はnil）
```

## See Also

- [Getting Started Tutorial](tutorials/getting-started.md)
- [Configuration Examples](examples/configurations.md)
- [Architecture Overview](architecture/overview.md)
