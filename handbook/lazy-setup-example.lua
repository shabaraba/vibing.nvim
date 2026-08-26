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

        -- Node.js実行ファイル設定（ランタイム）
        node = {
          executable = "auto",  -- "auto" or "/usr/local/bin/bun"
        },

        -- MCP統合設定
        mcp = {
          enabled = true,   -- MCP統合を有効化
          rpc_port = 9876,  -- RPCサーバーポート
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
        node = {
          executable = "auto",
        },
        mcp = {
          enabled = true,
          rpc_port = 9876,
        },
      })
    end,
  },
}
--]]
