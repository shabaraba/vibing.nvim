# Getting Started with vibing.nvim

このチュートリアルでは、vibing.nvimのインストールから基本的な使い方までを学びます。

## 目次

1. [前提条件](#前提条件)
2. [インストール](#インストール)
3. [基本設定](#基本設定)
4. [最初のチャット](#最初のチャット)
5. [インラインアクション](#インラインアクション)
6. [コンテキストの活用](#コンテキストの活用)
7. [よくある質問](#よくある質問)

## 前提条件

- Neovim 0.10.0以降
- Node.js 18以降（Agent SDK アダプター使用時）
- Claude Code CLI（推奨）

### Claude Code CLI のインストール

```bash
npm install -g @anthropics/claude-code
```

## インストール

### lazy.nvim

```lua
{
  "your-username/vibing.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("vibing").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "your-username/vibing.nvim",
  requires = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("vibing").setup()
  end,
}
```

### vim-plug

```vim
Plug 'nvim-lua/plenary.nvim'
Plug 'your-username/vibing.nvim'
```

```lua
-- init.lua
require("vibing").setup()
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
  -- アダプター選択（agent_sdk推奨）
  adapter = "agent_sdk",

  -- Agent SDK設定
  agent = {
    mode = "command",  -- commandモード（ツール使用なし）
    model = "claude-sonnet-4-5",  -- 使用モデル
  },

  -- チャットウィンドウ設定
  chat = {
    position = "right",  -- 右側に表示
    size = 80,           -- 幅80カラム
    auto_context = false,  -- 自動コンテキスト無効
    location_type = "project",  -- プロジェクトディレクトリに保存
  },

  -- キーマップ設定
  keymaps = {
    submit = "<C-CR>",  -- Ctrl+Enterで送信
    cancel = "<C-c>",   -- Ctrl+Cでキャンセル
  },
})
```

### カスタムキーマップ

```lua
vim.keymap.set("n", "<leader>cc", ":VibingChat<CR>", { desc = "Open chat" })
vim.keymap.set("v", "<leader>cf", ":VibingInline fix<CR>", { desc = "Fix selection" })
vim.keymap.set("v", "<leader>ce", ":VibingInline explain<CR>", { desc = "Explain selection" })
```

## 最初のチャット

### チャットを開く

```vim
:VibingChat
```

または設定したキーマップで：

```
<leader>cc
```

### メッセージを送信

1. チャットウィンドウで `## User` セクションの下にメッセージを入力
2. `<C-CR>`（Ctrl+Enter）で送信
3. Claudeの応答が `## Assistant` セクションに表示されます

**例：**

```markdown
## User

Luaでクイックソートを実装してください。
```

### チャットを保存

```vim
:w
```

チャットは `.vibing/chat/` ディレクトリに自動保存されます。

### 保存したチャットを開く

```vim
:VibingOpenChat .vibing/chat/quicksort-implementation.md
```

## インラインアクション

### コードを修正（fix）

1. ビジュアルモードでコードを選択
2. `:VibingInline fix` を実行
3. Claudeが選択範囲の問題を修正します

**例：**

```lua
-- 選択してから :VibingInline fix
function add(a b)  -- 引数にカンマがない
  return a + b
end
```

### コードを説明（explain）

1. ビジュアルモードでコードを選択
2. `:VibingInline explain` を実行
3. 出力バッファにコードの説明が表示されます

### その他のアクション

- **feat**: 新機能を実装
- **refactor**: コードをリファクタリング
- **test**: テストを生成

**カスタムプロンプト：**

```vim
:VibingInline "このコードを TypeScript に変換"
```

## コンテキストの活用

### 手動でファイルを追加

```vim
:VibingContext lua/vibing/init.lua
```

現在のバッファを追加：

```vim
:VibingContext
```

### コンテキストをクリア

```vim
:VibingClearContext
```

### 自動コンテキスト

開いている全バッファを自動的にコンテキストに含めます：

```lua
require("vibing").setup({
  chat = {
    auto_context = true,
  },
})
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

1. Claude Code CLIがインストールされているか: `claude --version`
2. APIキーが設定されているか
3. ネットワーク接続が正常か

### Q: エラー "Adapter 'agent_sdk' not found"

**A**: Agent SDKアダプターを使用するにはNode.jsが必要です。以下を確認：

```bash
node --version  # 18以降が必要
```

または、他のアダプターを使用：

```lua
require("vibing").setup({
  adapter = "claude",  -- Claude CLIを直接使用
})
```

### Q: キーマップが動作しない

**A**: 設定が正しく読み込まれているか確認：

```lua
:lua print(vim.inspect(require("vibing").get_config()))
```

### Q: チャットファイルの保存場所を変更したい

**A**: `location_type` を設定：

```lua
require("vibing").setup({
  chat = {
    location_type = "custom",
    custom_directory = "~/my-chats/",
  },
})
```

### Q: ストリーミングを無効にしたい

**A**: 現在のところ、Agent SDKアダプターはストリーミング専用です。非ストリーミングが必要な場合は、`claude` アダプターを使用してください。

## 次のステップ

- [API Reference](../api-reference.md) - 全APIの詳細
- [Configuration Examples](../examples/configurations.md) - 様々な設定例
- [Advanced Features](./advanced-features.md) - 高度な機能の活用

## トラブルシューティング

### ログの確認

```vim
:messages
```

### デバッグモード

```lua
vim.g.vibing_debug = true
```

### サポート

問題が解決しない場合は、以下にissueを作成してください：
https://github.com/your-username/vibing.nvim/issues

**報告時に含めるべき情報：**

- Neovimバージョン: `:version`
- プラグイン設定
- エラーメッセージ
- 再現手順
