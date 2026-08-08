# Getting Started with vibing.nvim

このチュートリアルでは、vibing.nvimのインストールから基本的な使い方までを学びます。

## 目次

1. [前提条件](#前提条件)
2. [インストール](#インストール)
3. [基本設定](#基本設定)
4. [最初のチャット](#最初のチャット)
5. [コンテキストの活用](#コンテキストの活用)
6. [よくある質問](#よくある質問)

## 前提条件

- Neovim 0.10.0以降（`vim.system()` を使用）
- Node.js 18以降（MCP サーバー用）
- AI CLI バックエンドを最低1つ:
  - Claude CLI（推奨）
  - Codex CLI

### CLI のインストール

```bash
# Claude CLI
npm install -g @anthropic-ai/claude-code

# Codex CLI（任意）
npm install -g @openai/codex
```

## インストール

### lazy.nvim

```lua
{
  "shabaraba/vibing.nvim",
  dependencies = {
    "stevearc/oil.nvim",  -- オプション: ファイルブラウザ統合
  },
  build = "./build.sh",  -- MCP サーバーのビルドと Claude Code プラグインの登録
  config = function()
    require("vibing").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "shabaraba/vibing.nvim",
  run = "./build.sh",
  config = function()
    require("vibing").setup()
  end,
}
```

## 基本設定

### 最小設定

デフォルト設定で動作します：

```lua
require("vibing").setup()
```

### おすすめ設定

```lua
require("vibing").setup({
  adapter = "claude",  -- "claude" | "codex"

  -- エージェント設定
  agent = {
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku" | "fable"
  },

  -- チャットウィンドウ設定
  chat = {
    window = {
      position = "right",  -- 右側に分割表示
      width = 0.4,         -- 画面幅の40%
    },
    save_location_type = "project",  -- プロジェクトの .vibing/chat/ に保存
  },

  -- キーマップ設定
  keymaps = {
    send = "<C-CR>",  -- Ctrl+Enterで送信（デフォルトは <CR>）
    cancel = "<C-c>", -- Ctrl+Cでキャンセル
  },
})
```

全オプションは [docs/configuration.md](../../docs/configuration.md) を参照してください。

### カスタムキーマップ

```lua
vim.keymap.set("n", "<leader>cc", ":VibingChat<CR>", { desc = "Open chat" })
```

## 最初のチャット

### チャットを開く

```vim
:VibingChat
```

または設定したキーマップで：

```text
<leader>cc
```

### メッセージを送信

1. チャットウィンドウで `## User` セクションの下にメッセージを入力
2. ノーマルモードで `<CR>`（設定変更時は `keymaps.send` のキー）で送信
3. AI の応答が `## Assistant` セクションに表示されます

**例：**

```markdown
## User

Luaでクイックソートを実装してください。
```

### チャットを保存

```vim
:w
```

チャットは `.vibing/chat/` ディレクトリに Markdown ファイルとして保存されます。

### 保存したチャットを開く

```vim
:VibingChat .vibing/chat/chat-20260101-120000-xxxx.md
```

保存済みチャットを開くと、frontmatter の `session_id` で会話が再開されます。

## コンテキストの活用

### 手動でファイルを追加

```vim
:VibingContext lua/vibing/init.lua
```

現在のバッファを追加：

```vim
:VibingContext
```

ビジュアル選択した範囲だけを追加することもできます（選択して `:VibingContext`）。

### コンテキストをクリア

```vim
:VibingClearContext
```

### チャット内でコンテキストを指定

チャット内で `/context` コマンドを使用：

```markdown
## User

/context lua/vibing/config.lua

この設定ファイルを改善してください。
```

## よくある質問

### Q: チャットが応答しない

**A**: 以下を確認してください：

1. CLI がインストールされているか: `claude --version`（または `codex --version`）
2. CLI のログイン・APIキーが設定されているか
3. ネットワーク接続が正常か

### Q: キーマップが動作しない

**A**: 設定が正しく読み込まれているか確認：

```vim
:lua print(vim.inspect(require("vibing").get_config()))
```

### Q: チャットファイルの保存場所を変更したい

**A**: `save_location_type` を設定：

```lua
require("vibing").setup({
  chat = {
    save_location_type = "custom",
    save_dir = "~/my-chats/",
  },
})
```

### Q: Codex を使いたい

**A**: グローバルには `adapter = "codex"`、チャット単位では frontmatter に `agent: codex` を指定します。

## 次のステップ

- [Configuration Reference](../../docs/configuration.md) - 全設定オプションの詳細
- [API Reference](../api-reference.md) - Lua API の詳細

## トラブルシューティング

### ログの確認

```vim
:messages
```

### ストリーミングのデバッグ

```lua
vim.g.vibing_debug_stream = true
```

### サポート

問題が解決しない場合は、以下にissueを作成してください：
<https://github.com/shabaraba/vibing.nvim/issues>

**報告時に含めるべき情報：**

- Neovimバージョン: `:version`
- プラグイン設定
- エラーメッセージ
- 再現手順
