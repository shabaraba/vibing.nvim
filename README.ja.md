<div align="center">

<img src=".github/assets/logo.png" alt="vibing.nvim logo" width="200"/>

# vibing.nvim

**Neovim用のインテリジェントAIコードアシスタント**

[![CI](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/shabaraba/vibing.nvim)](https://github.com/shabaraba/vibing.nvim/releases)

Agent SDKを通じて**Claude AI**をシームレスに統合し、エディタ内で直接、
インテリジェントなチャット会話とコンテキスト対応のインラインコードアクションを提供する強力なNeovimプラグインです。

[English](./README.md) | 日本語

[機能](#-機能) • [インストール](#-インストール) • [使い方](#-使い方) •
[設定例](#️-設定例) • [コントリビューション](#-コントリビューション)

</div>

---

## 目次

- [なぜvibing.nvimなのか？](#-なぜvibingnvimなのか)
- [機能](#-機能)
- [他のプラグインとの違い](#-他のプラグインとの違い)
- [インストール](#-インストール)
- [使い方](#-使い方)
- [設定例](#️-設定例)
- [設定リファレンス](#-設定リファレンス)
- [チャットファイル形式](#-チャットファイル形式)
- [アーキテクチャ](#️-アーキテクチャ)
- [FAQ](#-faq)
- [コントリビューション](#-コントリビューション)
- [ライセンス](#-ライセンス)
- [リンク](#-リンク)

## 💡 なぜvibing.nvimなのか？

vibing.nvimは、NeovimにおけるAI支援コーディングに対して、根本的に異なるアプローチを取っています。

### エージェント・ファーストなアーキテクチャ

従来のチャットベースAIプラグインがLLMに静的なコンテキストを送信するのとは異なり、
vibing.nvimはAgent SDKとMCP統合を通じて、ClaudeにNeovimインスタンスへの**直接アクセス**を与えます。

これにより、Claudeは以下のことが可能になります：

- **コードベースを自律的に探索** - 手動でコンテキストを設定することなく、ファイルをナビゲートし、シンボルを検索し、プロジェクト構造を理解
- **リアルタイムなエディタ状態へのアクセス** - LSP診断、シンボル定義、参照をオンデマンドでクエリ
- **Neovimコマンドの実行** - ワークフローの一部としてエディタ操作を実行
- **会話の継続性を維持** - `.vibing`ファイルに完全なコンテキストを保存してセッションを再開

### Claudeのために設計

vibing.nvimは、公式Agent SDKを活用してClaude専用に構築されており、
Claude Code CLIと同じ機能をNeovim内で直接提供します。
この焦点を絞ったアプローチにより、マルチプロバイダープラグインでは実現できない深い統合が可能になります。

## ✨ 機能

### 🤖 Neovimをエージェントツールとして活用

ClaudeはMCPを介して実行中のNeovimインスタンスと直接対話できます：

- バッファの読み書きをプログラマティックに実行
- ExコマンドとLuaコードの実行
- LSPによる診断、定義、参照、シンボルのクエリ
- プロジェクト内のファイルシステムのナビゲート

### 💾 ファイルベースのセッション永続化

各会話はYAMLフロントマター付きの`.vibing`ファイルとして保存されます：

- **ポータブル** - チームメイトやマシン間で会話を共有
- **再開可能** - 完全なSDKセッション状態で中断したところから正確に続行
- **監査可能** - すべての設定（モデル、モード、権限）がファイル内で可視化
- **バージョン管理可能** - AI支援による変更をGitで追跡

### 🛡️ きめ細かい権限システム

Claudeができることを細かく制御：

- 特定のツールの許可/拒否（Read、Edit、Write、Bashなど）
- センシティブファイルのパスベースルール
- シェル操作のコマンドパターンマッチング
- インタラクティブな権限ビルダーUI

### 📋 Accept/Reject機能付きインラインプレビュー

すべてのコード修正に対するTelescope風の差分プレビュー：

- 各変更ファイルの視覚的な差分表示
- Gitベースのrevertによるすべて承認/すべて拒否
- 複数の変更ファイル間のナビゲート
- インラインアクションとチャットモードの両方で動作

### その他の機能

- **💬 インタラクティブなチャットインターフェース** - Claude AIとのシームレスなチャットウィンドウ、デフォルトで現在のバッファに開く
- **⚡ インラインアクション** - 素早いコード修正、説明、リファクタリング、テスト生成
- **📝 自然言語コマンド** - あらゆるコード変換にカスタム指示を使用
- **🔧 スラッシュコマンド** - コンテキスト管理、権限、設定のためのチャット内コマンド
- **🎯 スマートコンテキスト** - 開いているバッファからの自動ファイルコンテキスト検出と手動追加
- **🌍 多言語サポート** - チャットとインラインアクションで異なる言語を設定可能
- **📊 差分ビューアー** - AI編集ファイルの視覚的な差分表示（`gd`キーバインド）
- **⚙️ 高度な設定可能性** - 柔軟なモード、モデル、権限、UI設定

## 🔄 他のプラグインとの違い

AIコーディングプラグインは、それぞれ異なるニーズに対応します。vibing.nvimの位置づけは以下の通りです：

### vibing.nvimが最適な場合：

- Claudeを主要なAIアシスタントとして使用している
- AIに自律的にコードベースをナビゲートして理解させたい
- 永続的で共有可能な会話履歴が必要
- きめ細かい権限制御を好む
- NeovimからClaude Code CLIの機能を使いたい

### 代替手段を検討すべき場合：

- 複数のLLMプロバイダー（OpenAI、Ollamaなど）のサポートが必要
- 最小限の依存関係を好む（vibing.nvimはNode.jsが必要）
- 大規模コミュニティを持つ実績あるプラグインを求めている（私たちはまだ成長中です！）

### 補完的な使用

vibing.nvimは深いClaude統合に焦点を当てています。以下の用途には他のツールも併用できます：

- クイック補完（GitHub Copilot、Codeium）
- ローカル/オフラインモデル（Ollamaベースのプラグイン）
- プロバイダー非依存のワークフロー

## 📦 インストール

### [lazy.nvim](https://github.com/folke/lazy.nvim)を使用

```lua
{
  "shabaraba/vibing.nvim",
  dependencies = {
    -- オプション：ファイルブラウザ統合用
    "stevearc/oil.nvim",
  },
  build = "./build.sh",  -- Neovim統合用MCPサーバーをビルド
  config = function()
    require("vibing").setup({
      -- デフォルト設定
      chat = {
        window = {
          position = "current",  -- "current" | "right" | "left" | "float"
          width = 0.4,
          border = "rounded",
        },
        auto_context = true,
        save_location_type = "project",  -- "project" | "user" | "custom"
        context_position = "append",  -- "prepend" | "append"
      },
      agent = {
        default_mode = "code",  -- "code" | "plan" | "explore"
        default_model = "sonnet",  -- "sonnet" | "opus" | "haiku"
        prioritize_vibing_lsp = true,  -- vibing-nvim LSPツールを優先（デフォルト：true）
      },
      permissions = {
        mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
        allow = { "Read", "Edit", "Write", "Glob", "Grep" },
        deny = { "Bash" },
        rules = {},  -- オプション：きめ細かい権限ルール
      },
      preview = {
        enabled = false,  -- 差分プレビューUIを有効化（Git必須）
      },
      language = nil,  -- オプション："ja" | "en" | { default = "ja", chat = "ja", inline = "en" }
    })
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)を使用

```lua
use {
  "shabaraba/vibing.nvim",
  run = "./build.sh",  -- Neovim統合用MCPサーバーをビルド
  config = function()
    require("vibing").setup()
  end,
}
```

## 🚀 使い方

### ユーザーコマンド

| コマンド                              | 説明                                                                       |
| ------------------------------------- | -------------------------------------------------------------------------- |
| `:VibingChat [position\|file]`        | オプションの位置（current\|right\|left）で新しいチャットを作成、または保存したファイルを開く |
| `:VibingToggleChat`                   | 既存のチャットウィンドウを切り替え（現在の会話を保持）                     |
| `:VibingSlashCommands`                | チャット内でスラッシュコマンドピッカーを表示                               |
| `:VibingContext [path]`               | コンテキストにファイルを追加（またはパスがない場合oil.nvimから）            |
| `:VibingClearContext`                 | すべてのコンテキストをクリア                                               |
| `:VibingInline [action\|instruction]` | リッチUIピッカー（引数なし）または直接実行（引数あり）。タブ補完有効。     |
| `:VibingInlineAction`                 | `:VibingInline`のエイリアス（後方互換性のため）                            |
| `:VibingCancel`                       | 現在のリクエストをキャンセル                                               |

**コマンドのセマンティクス：**

- **`:VibingChat`** - 常に新しいチャットウィンドウを作成します。オプションで位置（`current`、`right`、`left`）を指定してウィンドウ配置を制御できます。
  - `:VibingChat` - 設定のデフォルト位置を使用して新しいチャット
  - `:VibingChat current` - 現在のウィンドウに新しいチャット
  - `:VibingChat right` - 右分割に新しいチャット
  - `:VibingChat left` - 左分割に新しいチャット
  - `:VibingChat path/to/file.vibing` - 保存したチャットファイルを開く
- **`:VibingToggleChat`** - 現在の会話を表示/非表示にします。既存のチャット状態を保持します。

### インラインアクション

**リッチUIピッカー（推奨）：**

```vim
:'<,'>VibingInline
" 分割パネルUIを開きます：
" - 左：アクションメニュー（fix、feat、explain、refactor、test）
"   j/kまたは矢印キーでナビゲート、Tabで入力に移動
" - 右：追加指示入力（オプション）
"   Shift-Tabでメニューに戻る
" - Enterで実行、Esc/Ctrl-cでキャンセル
```

**キーバインディング：**

- `j`/`k` または `↓`/`↑` - アクションメニューをナビゲート
- `Tab` - メニューから入力フィールドに移動
- `Shift-Tab` - 入力フィールドからメニューに移動
- `Enter` - 選択したアクションを実行
- `Esc` または `Ctrl-c` - キャンセル

**直接実行（引数あり）：**

```vim
:'<,'>VibingInline fix       " コードの問題を修正
:'<,'>VibingInline feat      " 機能を実装
:'<,'>VibingInline explain   " コードを説明
:'<,'>VibingInline refactor  " コードをリファクタリング
:'<,'>VibingInline test      " テストを生成

" 追加指示付き
:'<,'>VibingInline fix async/awaitを使って
:'<,'>VibingInline test Jestのモックで
```

**自然言語指示：**

```vim
:'<,'>VibingInline "この関数をTypeScriptに変換"
:'<,'>VibingInline "try-catchでエラーハンドリングを追加"
:'<,'>VibingInline "このループをパフォーマンス最適化"
```

### インラインプレビューUI

設定で`preview.enabled = true`が設定されている場合、インラインアクション実行後にTelescope風のプレビューUIを表示します（Gitリポジトリ必須）：

**レイアウト：**

インラインモード（3パネル）：

```text
┌──────────────┬──────────────────────────────────────┐
│ Files (3)    │ Diff Preview                         │
│  > src/a.lua │  @@ -10,5 +10,8 @@                   │
│    src/b.lua │  -old line                           │
│    tests/*.lua  +new line                           │
├──────────────┴──────────────────────────────────────┤
│ Response: Modified 3 files successfully             │
└─────────────────────────────────────────────────────┘
```

チャットモード（2パネル）：

```text
┌──────────────┬──────────────────────────────────────┐
│ Files (3)    │ Diff Preview                         │
│  > src/a.lua │  @@ -10,5 +10,8 @@                   │
│    src/b.lua │  -old line                           │
│    tests/*.lua  +new line                           │
└──────────────┴──────────────────────────────────────┘
```

**キーバインディング：**

- `j`/`k` - カーソルを上下に移動（通常のNeovimナビゲーション）
- `<Enter>` - カーソル位置のファイルを選択（Filesウィンドウ内）
- `<Tab>` - 次のウィンドウにサイクル（Files → Diff → Response → Files）
- `<Shift-Tab>` - 前のウィンドウにサイクル
- `a` - すべての変更を承認（プレビューを閉じて変更を保持）
- `r` - すべての変更を拒否（`git checkout HEAD`を使用してすべてのファイルを元に戻す）
- `q`/`Esc` - プレビューを閉じる（変更を保持）

**機能：**

- レスポンシブレイアウト（横幅 ≥120列で水平、<120列で垂直）
- Delta統合による強化された差分ハイライト（利用可能な場合）
- 複数の変更ファイル間のナビゲート
- 個別またはすべての変更を承認/拒否
- Gitベースの元に戻す機能

### スラッシュコマンド（チャット内）

| コマンド                  | 説明                                                    |
| ------------------------- | ------------------------------------------------------- |
| `/context <file>`         | コンテキストにファイルを追加                            |
| `/clear`                  | コンテキストをクリア                                    |
| `/save`                   | 現在のチャットを保存                                    |
| `/summarize`              | 会話を要約                                              |
| `/mode <mode>`            | 実行モードを設定（auto/plan/code/explore）              |
| `/model <model>`          | AIモデルを設定（opus/sonnet/haiku）                     |
| `/permissions` または `/perm` | インタラクティブな権限ビルダー - ツールの許可/拒否ルールを設定 |
| `/allow [tool]`           | 許可リストにツールを追加、引数なしで現在のリストを表示  |
| `/deny [tool]`            | 拒否リストにツールを追加、引数なしで現在のリストを表示  |

### チャットキーバインディング

チャットバッファ内では、以下のキーバインディングが使用できます：

| キー | 説明                                                                         |
| ---- | ---------------------------------------------------------------------------- |
| `gd` | カーソル下のファイルの差分を表示（Modified Filesセクション内）                |
| `gf` | カーソル下のファイルを開く（Modified Filesセクション内）                      |
| `gp` | **すべての変更ファイルをプレビュー** - Telescope風のプレビューUIを開く（Git必須） |
| `q`  | チャットウィンドウを閉じる                                                   |

**すべての変更ファイルをプレビュー（`gp`）：**

Claudeがチャットセッションで複数のファイルを変更した場合、チャットバッファ内の任意の場所で`gp`を押すと、
すべての変更ファイルを一度に表示するインラインプレビューUIが開きます。これにより、インラインアクションと同じAccept/Reject機能が提供されます：

- `j`/`k`でファイル間をナビゲート
- `a`を押してすべての変更を承認
- `r`を押してすべての変更を拒否して元に戻す（`git checkout HEAD`経由）
- `q`を押してプレビューを終了

## ⚙️ 設定例

### 基本セットアップ

```lua
require("vibing").setup()
```

設定を提供しない場合、以下の**デフォルト権限**が適用されます：

```lua
permissions = {
  mode = "acceptEdits",  -- ファイル編集を自動承認、他のツールは確認
  allow = {
    "Read",    -- ファイルを読む
    "Edit",    -- ファイルを編集
    "Write",   -- 新しいファイルを書く
    "Glob",    -- パターンでファイルを検索
    "Grep",    -- ファイル内容を検索
  },
  deny = {
    "Bash",    -- シェルコマンドをブロック（セキュリティ）
  },
}
```

これらのデフォルトは、新しいチャットファイルを作成する際の**テンプレート**として使用されます。
各チャットファイルのフロントマターには独自の権限が含まれ、実行時に使用されます。

### カスタム設定

```lua
require("vibing").setup({
  chat = {
    window = {
      position = "float",
      width = 0.6,
      border = "single",
    },
    save_location_type = "user",  -- グローバルチャット履歴
  },
  agent = {
    default_mode = "plan",  -- プランニングモードで開始
    default_model = "opus",  -- 最も能力の高いモデルを使用
  },
  permissions = {
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "WebSearch" },
    deny = {},  -- すべてのツールを許可
  },
  preview = {
    enabled = true,  -- 差分プレビューUIを有効化
  },
  keymaps = {
    send = "<C-CR>",  -- カスタム送信キー
    cancel = "<C-c>",
    add_context = "<C-a>",
  },
})
```

### プロジェクト固有の設定

```lua
-- チャットをプロジェクトディレクトリに保存
require("vibing").setup({
  chat = {
    save_location_type = "project",  -- プロジェクトルートの.vibing/chat/
  },
})
```

### カスタム保存場所

```lua
require("vibing").setup({
  chat = {
    save_location_type = "custom",
    save_dir = "~/my-ai-chats/vibing/",
  },
})
```

### きめ細かい権限ルール

```lua
require("vibing").setup({
  permissions = {
    mode = "default",  -- 毎回確認を求める
    rules = {
      -- 特定のパスの読み取りを許可
      {
        tools = { "Read" },
        paths = { "src/**", "tests/**" },
        action = "allow",
      },
      -- 重要なファイルへの書き込みを拒否
      {
        tools = { "Write", "Edit" },
        paths = { ".env", "*.secret" },
        action = "deny",
        message = "機密ファイルは変更できません",
      },
      -- 特定のnpmコマンドのみ許可
      {
        tools = { "Bash" },
        commands = { "npm", "yarn" },
        action = "allow",
      },
      -- 危険なbashパターンを拒否
      {
        tools = { "Bash" },
        patterns = { "^rm -rf", "^sudo" },
        action = "deny",
        message = "危険なコマンドがブロックされました",
      },
    },
  },
})
```

### 多言語設定

```lua
require("vibing").setup({
  -- シンプル：すべてのレスポンスを日本語で
  language = "ja",

  -- 高度：チャットとインラインで異なる言語
  -- language = {
  --   default = "ja",
  --   chat = "ja",     -- チャットは日本語
  --   inline = "en",   -- インラインアクションは英語
  -- },
})
```

## 📚 設定リファレンス

すべての設定オプションの完全なリファレンス：

### Agent設定

Claude Agent SDKの動作を制御：

```lua
agent = {
  default_mode = "code",    -- デフォルト実行モード
                            -- "code": 直接実装
                            -- "plan": まず計画してから実装
                            -- "explore": コードベースを探索・分析

  default_model = "sonnet", -- デフォルトClaudeモデル
                            -- "sonnet": バランス型（推奨）
                            -- "opus": 最も能力が高い
                            -- "haiku": 最速

  prioritize_vibing_lsp = true,  -- vibing-nvim LSPツールを優先
                                 -- true: vibing-nvim LSPを使用（実行中のNeovimに接続）
                                 -- false: 汎用LSPツール（例：Serena）を許可
                                 -- デフォルト：true
}
```

### Chat設定

チャットウィンドウとセッション設定：

```lua
chat = {
  window = {
    position = "current",  -- ウィンドウ位置
                          -- "current": 現在のウィンドウに開く
                          -- "right": 右垂直分割
                          -- "left": 左垂直分割
                          -- "float": フローティングウィンドウ

    width = 0.4,          -- ウィンドウ幅（0-1: 比率、>1: 絶対列数）
    border = "rounded",   -- ボーダースタイル："rounded" | "single" | "double" | "none"
  },

  auto_context = true,     -- 開いているバッファを自動的にコンテキストに追加

  save_location_type = "project",  -- チャットファイルの保存場所
                                   -- "project": プロジェクトルートの.vibing/chat/
                                   -- "user": ~/.local/share/nvim/vibing/chats/
                                   -- "custom": save_dirパスを使用

  save_dir = "~/.local/share/nvim/vibing/chats",  -- save_location_type="custom"の場合に使用

  context_position = "append",  -- 新しいコンテキストファイルを追加する場所
                               -- "append": コンテキストリストの末尾に追加
                               -- "prepend": 先頭に追加
}
```

### Permissions（権限）

Claudeが使用できるツールを制御。詳細な例については[きめ細かい権限ルール](#きめ細かい権限ルール)を参照してください。

```lua
permissions = {
  mode = "acceptEdits",  -- 権限モード
                        -- "default": 毎回確認を求める
                        -- "acceptEdits": Edit/Writeを自動承認（推奨）
                        -- "bypassPermissions": すべてを自動承認（慎重に使用）

  allow = {              -- 許可するツール（空 = 拒否されたもの以外すべて許可）
    "Read",              -- ファイルを読む
    "Edit",              -- 既存ファイルを編集
    "Write",             -- 新しいファイルを作成
    "Glob",              -- パターンでファイルを検索
    "Grep",              -- ファイル内容を検索
    -- "Bash",           -- シェルコマンドを実行（セキュリティリスク）
    -- "WebSearch",      -- Webを検索
    -- "WebFetch",       -- Webページを取得
  },

  deny = {               -- 拒否するツール（allowより優先）
    "Bash",              -- デフォルトでシェルコマンドをブロック
  },

  rules = {},            -- 高度：きめ細かい権限ルール
                        -- きめ細かい権限ルールセクションを参照
}
```

### Keymaps（キーマップ）

チャットバッファのキーバインディング：

```lua
keymaps = {
  send = "<CR>",         -- メッセージを送信
  cancel = "<C-c>",      -- 現在のリクエストをキャンセル
  add_context = "<C-a>", -- コンテキストにファイルを追加
  open_diff = "gd",      -- ファイルパス上で差分ビューアーを開く
  open_file = "gf",      -- ファイルパス上でファイルを開く
}
```

### Preview設定

インラインアクションとチャット用の差分プレビューUIを設定：

```lua
preview = {
  enabled = false,  -- Telescope風の差分プレビューUIを有効化
                    -- Gitリポジトリが必要
                    -- コード変更後にAccept/Reject UIを表示
                    -- git diffとgit checkoutを使用して元に戻す
                    -- インラインアクションとチャット（gpキー）の両方で動作
}
```

### UI設定

UIの外観と動作を設定：

```lua
ui = {
  wrap = "on",  -- 行の折り返し動作
                -- "nvim": Neovimのデフォルトを尊重（ラップ設定を変更しない）
                -- "on": wrap + linebreakを有効化（チャット可読性のため推奨）
                -- "off": 行の折り返しを無効化

  tool_result_display = "compact",  -- ツール実行結果の表示モード
                                    -- "none": ツール結果を表示しない
                                    -- "compact": 最初の100文字のみ表示（デフォルト）
                                    -- "full": 完全なツール出力を表示

  gradient = {
    enabled = true,  -- AIレスポンス中のグラデーションアニメーションを有効化
    colors = {
      "#cc3300",  -- 開始色（オレンジ、vibing.nvimロゴに合わせて）
      "#fffe00",  -- 終了色（黄色、vibing.nvimロゴに合わせて）
    },
    interval = 100,  -- アニメーション更新間隔（ミリ秒）
  },
}
```

### MCP（Model Context Protocol）

ClaudeによるNeovimの直接制御を有効化：

```lua
mcp = {
  enabled = false,               -- MCP統合を有効化
  rpc_port = 9876,              -- RPCサーバーポート
  auto_setup = false,           -- プラグインインストール時にMCPサーバーを自動ビルド
  auto_configure_claude_json = false,  -- ~/.claude.jsonを自動設定
}
```

**`auto_configure_claude_json`とは？**

有効にすると、vibing.nvim MCPサーバーを`~/.claude.json`に自動的に追加します：

```json
{
  "mcpServers": {
    "vibing-nvim": {
      "command": "node",
      "args": ["/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": { "VIBING_RPC_PORT": "9876" }
    }
  }
}
```

これにより、Claude Code CLIがNeovimインスタンスを制御できるようになります（バッファの読み書き、コマンド実行）。

**lazy.nvim推奨設定：**

```lua
{
  "shabaraba/vibing.nvim",
  build = "./build.sh",
  config = function()
    require("vibing").setup({
      mcp = {
        enabled = true,
        auto_setup = true,              -- インストール時にビルド
        auto_configure_claude_json = true,  -- 自動設定
      },
    })
  end,
}
```

### Language（言語）

AIレスポンスの言語を設定：

```lua
-- シンプル：すべてのレスポンスを1つの言語で
language = "ja"  -- または "en"、"fr"など

-- 高度：コンテキストごとに異なる言語
language = {
  default = "ja",  -- デフォルト言語
  chat = "ja",     -- チャットウィンドウのレスポンス
  inline = "en",   -- インラインアクションのレスポンス
}
```

### Remote Control（リモート制御）

テストと開発用（高度）：

```lua
remote = {
  socket_path = nil,   -- NVIM環境変数から自動検出
  auto_detect = true,  -- リモート制御検出を有効化
}
```

## 📝 チャットファイル形式

チャットはセッション再開と設定のためにYAMLフロントマター付きMarkdownとして保存されます：

```yaml
---
vibing.nvim: true
session_id: <sdk-session-id>
created_at: 2024-01-01T12:00:00
mode: code  # auto | plan | code | explore
model: sonnet  # sonnet | opus | haiku
permissions_mode: acceptEdits  # default | acceptEdits | bypassPermissions
permissions_allow:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
permissions_deny:
  - Bash
language: ja  # オプション：AIレスポンスのデフォルト言語
---
# Vibing Chat

## User

こんにちは、Claude！

## Assistant

こんにちは！今日はどのようにお手伝いできますか？
```

**主な機能：**

- **セッション再開**：`session_id`を使用して自動的に会話を再開
- **設定追跡**：透明性のためにモード、モデル、権限を記録
- **言語サポート**：オプションの`language`フィールドでセッション全体で一貫したAIレスポンス言語を確保
- **監査可能性**：すべての権限がフロントマターで可視化

## 🏗️ アーキテクチャ

詳細なアーキテクチャドキュメントについては、[CLAUDE.md](./CLAUDE.md)を参照してください。

### 高レベル概要

```text
┌─────────────────────────────────────────────────────────┐
│                      Neovim                             │
│  ┌───────────────┐     ┌─────────────────────────────┐  │
│  │ vibing.nvim   │────▶│  Chat Buffer (.vibing)      │  │
│  │ (Lua plugin)  │     │  - Markdown + YAML          │  │
│  └───────┬───────┘     │  - Session metadata         │  │
│          │             │  - Permission settings      │  │
│          ▼             └─────────────────────────────┘  │
│  ┌───────────────┐                                      │
│  │ RPC Server    │◀─────────────────────┐               │
│  └───────┬───────┘                      │               │
└──────────┼──────────────────────────────┼───────────────┘
           │                              │
           ▼                              │
┌─────────────────────┐    ┌──────────────┴──────────────┐
│ Claude Agent SDK    │    │ MCP Server                  │
│ (Node.js)           │───▶│ - Buffer operations         │
│                     │    │ - LSP queries               │
│ - Tool execution    │    │ - Command execution         │
│ - Session management│    │ - File system access        │
│ - Streaming response│    └─────────────────────────────┘
└─────────────────────┘
```

### 従来のアプローチとの違い

| 側面           | 従来のREST API      | vibing.nvim (Agent SDK) |
| -------------- | ------------------- | ----------------------- |
| コンテキスト   | 手動で組み立て      | エージェントがオンデマンドでリクエスト |
| エディタアクセス | なし（fire & forget） | 完全な双方向MCP         |
| セッション状態 | プラグインが管理    | 再開サポート付きSDK     |
| ツール実行     | プラグインが実装    | SDK標準ツール           |
| 機能           | プラグインに制限    | MCPで拡張可能           |

**主要コンポーネント：**

- **Agent SDK統合** - JSON Lines経由で通信するNode.jsラッパー
- **MCPサーバー** - Claudeに直接Neovim制御を提供
- **コンテキストシステム** - 自動および手動のファイルコンテキスト管理
- **セッション永続化** - 完全な履歴で会話を再開

### ディレクトリ構造

vibing.nvimは、Neovimプラグイン（Lua）とNode.jsバックエンド（Agent SDK/MCP）を組み合わせたハイブリッドプロジェクトです。
この構造は、Neovimプラグインの慣例とNode.jsエコシステムの標準の両方に従っています。

**Neovimプラグイン（Neovimランタイムに必要）：**

- `lua/` - プラグイン実装（Luaモジュール）
- `plugin/` - 自動ロードされるプラグインエントリーポイント
- `doc/` - ヘルプドキュメント（`:help vibing`）
- `ftplugin/` - `.vibing`チャットファイル用のファイルタイプ固有設定

**Node.jsバックエンド：**

- `bin/` - Agent SDK用実行可能ラッパー
- `mcp-server/` - Neovim制御用MCP統合サーバー
- `tests/` - テストスイート（LuaとNode.jsのテスト）
- `package.json` - Node.js依存関係とスクリプト

**ドキュメント：**

- `README.md` - メインユーザードキュメント
- `CLAUDE.md` - AI開発ガイドラインとアーキテクチャ詳細
- `docs/` - 開発者ガイド（アダプター開発、パフォーマンス、例）
- `CONTRIBUTING.md` - コントリビューションガイド

**開発設定：**

- `.editorconfig`、`.prettierrc` - コードスタイルの一貫性
- `eslint.config.mjs` - リント設定
- `.github/` - CI/CDワークフローとissueテンプレート
- `build.sh` - MCPサーバー用ビルドスクリプト

## ❓ FAQ

### なぜClaude専用なのか？他のプロバイダーをサポートしないのはなぜ？

vibing.nvimは、単純なチャット以上の機能を提供するClaude Agent SDKを使用しています：

- 組み込みツール実行フレームワーク
- セッション永続化と再開
- エディタ制御のためのMCP統合

これらの機能はClaudeのアーキテクチャに固有のものです。他のプロバイダーをサポートすることは、次のいずれかを意味します：

- これらの機能を失う、または
- ゼロから再実装する

私たちは幅よりも深さを選びました。

### なぜNode.jsが必要なのか？

Claude Agent SDKはTypeScript/JavaScriptライブラリです。Luaバインディングを作成することも可能ですが、
Node.jsを直接使用することで以下が保証されます：

- 完全なSDK互換性
- 新しいSDK機能への即座のアクセス
- 信頼性の高いMCPサーバー実装

### Claude Code CLIと比較してどうか？

vibing.nvimは、Claude Code CLIと同様の機能をNeovimに統合して提供します：

- 同じAgent SDKを基盤として使用
- 同じツール実行モデル
- エディタ制御のためのMCP（CLIはターミナルを制御、vibingはNeovimを制御）

「Neovimユーザー向けのClaude Code」と考えてください。

### vibing.nvimを他のAIプラグインと併用できるか？

はい。vibing.nvimは補完プラグイン（Copilot、Codeium）や他のチャットプラグインと競合しません。
深いClaude対話にはvibing.nvimを使用し、クイック補完や異なるプロバイダーには他のツールを使用してください。

## 🤝 コントリビューション

コントリビューションを歓迎します！issueやプルリクエストをお気軽に提出してください。

## 📄 ライセンス

MITライセンス - 詳細はLICENSEファイルを参照

## 🔗 リンク

- [Claude AI](https://claude.ai)
- [Claude Agent SDK](https://github.com/anthropics/anthropic-sdk-typescript)
- [GitHubリポジトリ](https://github.com/shabaraba/vibing.nvim)

---

Made with ❤️ using Claude Code
