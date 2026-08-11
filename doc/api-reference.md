# API Reference

vibing.nvim が公開している API のリファレンス。設定項目そのものは
[docs/configuration.md](../docs/configuration.md) を参照。

## 目次

- [Core API](#core-api)
- [Adapter API](#adapter-api)
- [Internal Modules](#internal-modules)
- [Types](#types)

## Core API

### `vibing.setup(opts)`

プラグインを初期化します。

**Parameters:**

- `opts` (`Vibing.Config?`): 設定オプション（省略可）

**Example:**

```lua
require("vibing").setup({
  adapter = "claude",  -- "claude" | "codex"
  agent = {
    default_mode = "code",     -- "code" | "plan" | "explore"
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku" | "fable"
  },
  chat = {
    window = {
      position = "right",  -- "current" | "right" | "left" | "top" | "bottom" | "back" | "float"
      width = 0.4,         -- 画面幅に対する比率（0-1）
    },
    save_location_type = "project",
  },
})
```

全オプションは [docs/configuration.md](../docs/configuration.md) を参照してください。

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
print(config.adapter)  -- "claude"
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

#### Claude CLI Adapter

`claude` CLI を直接 spawn するアダプター（デフォルト）。
`claude -p --output-format stream-json` の出力をパースする。

**Configuration:**

```lua
{
  adapter = "claude",
  agent = {
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku" | "fable"
  },
}
```

**Features:**

- ✅ Streaming
- ✅ Tools
- ✅ Model selection
- ✅ Context
- ✅ Session management（`--resume <session_id>`）

**Implementation:** `lua/vibing/infrastructure/adapter/claude_cli.lua`

#### Codex CLI Adapter

OpenAI の `codex` CLI（`codex exec --json`）を使用するアダプター。

**Configuration:**

```lua
{
  adapter = "codex",
}
```

チャットごとに切り替える場合は frontmatter の `agent: codex` を使う。

**Features:**

- ✅ Streaming
- ✅ Tools
- ✅ Model selection
- ✅ Context
- ✅ Session management

**Implementation:** `lua/vibing/infrastructure/adapter/codex_cli.lua`

## Internal Modules

`vibing.setup()` / `vibing.get_adapter()` / `vibing.get_config()` と、上のアダプター
インターフェース以外は内部実装であり、予告なく変わる。

以前このドキュメントには Context API (`require("vibing.context")`)、Chat Buffer API、
Output Buffer API の節があったが、いずれも v4 のレイヤー分割で移動・削除されており、
記載どおりのモジュールはもう存在しない（`vibing.context` と Output Buffer は現存せず、
チャットバッファは `vibing.presentation.chat.buffer` に移り、メソッド構成も変わっている）。
誤った API を載せ続けるより外すほうが害が小さいため、節ごと削除した。

現在のモジュール構成は `.claude/rules/architecture.md` の "Module Structure" を参照。

## Types

### `Vibing.Config`

```lua
---@class Vibing.Config
---@field adapter "claude"|"codex" バックエンドアダプター選択
---@field agent Vibing.AgentConfig エージェント設定（モード、モデル）
---@field chat Vibing.ChatConfig チャット設定
---@field ui Vibing.UiConfig UI設定
---@field keymaps Vibing.KeymapConfig キーマップ設定
---@field diff Vibing.DiffConfig diff表示設定
---@field permissions Vibing.PermissionsConfig 権限設定
---@field node Vibing.NodeConfig Node.js実行ファイル設定
---@field mcp Vibing.McpConfig MCP統合設定
---@field language string|Vibing.LanguageConfig? AI応答のデフォルト言語
---@field daily_summary Vibing.DailySummaryConfig? Daily Summary機能設定
```

### `Vibing.AdapterOpts`

```lua
---@class Vibing.AdapterOpts
---@field streaming boolean ストリーミング有効化
---@field tools string[] 使用するツール名の配列
---@field model string モデル名
---@field context string[] コンテキストファイル（@file:path形式）
```

これはアダプターインターフェースが要求する最小の形。実行時には
`send_message` が権限・セッション・cwd などの内部フィールドも載せて渡す
（`lua/vibing/core/types.lua` の同名クラスが全項目）。

### `Vibing.Response`

```lua
---@class Vibing.Response
---@field content string 応答テキスト
---@field error string? エラーメッセージ（成功時はnil）
```

## See Also

- [Configuration Reference](../docs/configuration.md)
- [`:help vibing`](./vibing.txt)
- [Architecture](../.claude/rules/architecture.md)
