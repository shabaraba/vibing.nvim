-- Lazy.nvim setup example for vibing.nvim with auto MCP setup
-- Place this in ~/.config/nvim/lua/plugins/vibing.lua

return {
  {
    "yourusername/vibing.nvim",
    dependencies = {
      -- Add any dependencies here
    },

    -- Build MCP server automatically on install/update
    -- Method 1: Shell script (simplest, recommended)
    build = "./build.sh",

    -- Method 1b: Use custom Node.js executable during build
    -- build = "VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh",

    -- Method 2: Lua function (more flexible)
    -- build = function()
    --   require("vibing.install").build()
    -- end,

    config = function()
      require("vibing").setup({
        adapter = "agent_sdk",

        -- Node.js実行ファイル設定（ランタイム）
        node = {
          executable = "auto",  -- "auto" or "/usr/local/bin/bun"
        },

        -- MCP統合設定
        mcp = {
          enabled = true,  -- MCP統合を有効化
          rpc_port = 9876,  -- RPCサーバーポート

          -- 自動セットアップオプション
          auto_setup = true,  -- プラグイン読み込み時に自動的にMCPサーバーをビルド
          auto_configure_claude_json = true,  -- ~/.claude.jsonを自動設定
        },

        -- 他の設定...
        permissions = {
          mode = "acceptEdits",
          allow = {
            "Read",
            "Edit",
            "Write",
            "Glob",
            "Grep",
          },
          deny = {
            "Bash",
          },
        },
      })
    end,
  },
}

-- ==========================================
-- パターン1: 完全自動セットアップ（推奨）
-- ==========================================
-- プラグインインストール時に自動的にすべてセットアップ
-- - Lazy.nvimのbuildフックでMCPサーバービルド
-- - auto_setup = true でビルド状態チェック
-- - auto_configure_claude_json = true で ~/.claude.json 自動設定

return {
  {
    "yourusername/vibing.nvim",
    build = "./build.sh",  -- シンプルなワンコマンド
    -- または: build = "VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh",  -- カスタムNode.js実行ファイル
    config = function()
      require("vibing").setup({
        node = {
          executable = "auto",  -- "auto" or "/usr/local/bin/bun"
        },
        mcp = {
          enabled = true,
          auto_setup = true,
          auto_configure_claude_json = true,
        },
      })
    end,
  },
}

-- ==========================================
-- パターン2: ビルドのみ自動、設定は手動
-- ==========================================
-- MCPサーバーは自動ビルドするが、claude.jsonは手動で設定
-- セキュリティ重視の場合や既存設定がある場合に推奨

return {
  {
    "yourusername/vibing.nvim",
    build = "cd mcp-server && npm install && npm run build",
    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          auto_setup = true,
          auto_configure_claude_json = false,  -- 手動設定
        },
      })

      -- 初回のみ手動でセットアップウィザードを実行
      -- :VibingSetupMcp
    end,
  },
}

-- ==========================================
-- パターン3: すべて手動
-- ==========================================
-- 完全にコントロールしたい場合

return {
  {
    "yourusername/vibing.nvim",
    -- buildフックなし（手動でビルド）
    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          auto_setup = false,
          auto_configure_claude_json = false,
        },
      })

      -- 手動でセットアップ:
      -- 1. :VibingBuildMcp でMCPサーバービルド
      -- 2. :VibingConfigureClaude で ~/.claude.json 設定
      -- または
      -- :VibingSetupMcp で対話的セットアップ
    end,
  },
}

-- ==========================================
-- パターン4: Lua関数でビルド
-- ==========================================
-- Lua関数を使った柔軟なビルド方法

return {
  {
    "yourusername/vibing.nvim",
    build = function()
      -- 組み込みのビルド関数を使用
      require("vibing.install").build()
    end,

    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          auto_configure_claude_json = true,
        },
      })
    end,
  },
}

-- ==========================================
-- パターン5: 開発用セットアップ
-- ==========================================
-- ローカル開発時に使用

return {
  {
    dir = "~/projects/vibing.nvim",  -- ローカルパス
    build = "cd mcp-server && npm install && npm run dev",  -- Watch mode

    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          rpc_port = 9876,
          auto_setup = false,  -- 開発時は手動
          auto_configure_claude_json = false,
        },
      })
    end,
  },
}

-- ==========================================
-- 追加の便利なコマンド
-- ==========================================
-- セットアップ後に使えるコマンド:
--
-- :VibingBuildMcp           - MCPサーバーを再ビルド
-- :VibingSetupMcp           - 対話的セットアップウィザード
-- :VibingConfigureClaude    - ~/.claude.jsonを設定（上書き）
--
-- 使用例:
-- 1. プラグイン更新後にMCPサーバーを再ビルド
--    :VibingBuildMcp
--
-- 2. 設定を変更した後にclaude.jsonを更新
--    :VibingConfigureClaude
--
-- 3. 初めてセットアップする場合
--    :VibingSetupMcp
