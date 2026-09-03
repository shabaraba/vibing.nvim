-- Lazy.nvim setup example for vibing.nvim
-- Place this in ~/.config/nvim/lua/plugins/vibing.lua
--
-- The MCP server reaches Claude Code as part of vibing.nvim's own bundled plugin, which is
-- handed to the CLI per session with `--plugin-dir` -- nothing is installed, and build.sh only
-- builds it. There is no separate ~/.claude.json registration path: that route can only ever
-- hardcode a single default RPC port, so it silently targets the wrong Neovim instance whenever
-- more than one is running.

return {
  {
    "yourusername/vibing.nvim",
    dependencies = {
      -- Add any dependencies here
    },

    -- Build the bundled MCP server on install/update
    build = "./build.sh",

    -- Use a custom Node.js executable during build:
    -- build = "VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh",

    config = function()
      require("vibing").setup({
        adapter = "claude",

        -- MCP統合設定
        mcp = {
          enabled = true,   -- MCP統合を有効化
          rpc_port = 9876,  -- RPCサーバーポート
        },

        agent = {
          -- 各ターンの末尾に `### Tokens` を出し、コンテキストが育ったら章の中で警告する。
          -- ターンのコストは「リクエスト数 × コンテキストサイズ」で決まるので、ツールを
          -- 多く呼ぶターンほど、また会話が長いほど高くつく。
          token_usage = {
            enabled = true,
            -- この値を超えている間、毎ターン警告が付く。
            --
            -- 上げる目安: チャットには下限があり、システムプロンプト・ツールスキーマ・
            -- プロジェクトの CLAUDE.md と .claude/rules で決まる。大きな CLAUDE.md を持つ
            -- リポジトリでは会話が空でも 110k 前後になるため、既定の 150000 だと会話が
            -- 40k 育っただけで警告が出る。うるさければ 250000 程度に上げる。
            warn_context = 150000,
          },
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
-- 開発用セットアップ
-- ==========================================
-- ローカル開発時に使用

--[[ 開発用パターン:
return {
  {
    dir = "~/projects/vibing.nvim",  -- ローカルパス
    build = "cd claude-plugin/mcp-server && npm install && npm run dev",  -- Watch mode

    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          rpc_port = 9876,
        },
      })
    end,
  },
}
--]]
