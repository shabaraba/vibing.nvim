local grok_lightweight = require("vibing.infrastructure.adapter.modules.grok_lightweight")

describe("grok_lightweight", function()
  local original_stdpath
  local original_notify
  local cache_root

  before_each(function()
    cache_root = vim.fn.tempname()
    original_stdpath = vim.fn.stdpath
    original_notify = vim.notify
    vim.fn.stdpath = function(what)
      if what == "cache" then
        return cache_root
      end
      return original_stdpath(what)
    end
    vim.notify = function() end
    package.loaded["vibing.infrastructure.adapter.modules.grok_lightweight"] = nil
    grok_lightweight = require("vibing.infrastructure.adapter.modules.grok_lightweight")
  end)

  after_each(function()
    vim.fn.stdpath = original_stdpath
    vim.notify = original_notify
    vim.fn.delete(cache_root, "rf")
  end)

  describe("append_flags", function()
    local function value_after(cmd, flag)
      for i, arg in ipairs(cmd) do
        if arg == flag then
          return cmd[i + 1]
        end
      end
      return nil
    end

    it("names a real tool, because grok's allowlist fails open on one it cannot map", function()
      local cmd = {}
      grok_lightweight.append_flags(cmd)
      assert.equals("todo_write", value_after(cmd, "--tools"))
    end)

    it("denies the MCP tools the allowlist cannot reach", function()
      local cmd = {}
      grok_lightweight.append_flags(cmd)
      assert.equals("MCPTool(*)", value_after(cmd, "--deny"))
    end)

    it("never waits on an approval prompt no hook is registered to answer", function()
      local cmd = {}
      grok_lightweight.append_flags(cmd)
      assert.equals("dontAsk", value_after(cmd, "--permission-mode"))
    end)
  end)

  describe("apply_env", function()
    it("turns off the claude and cursor compat cells that reach a utility call", function()
      -- These are the per-invocation form of `[compat.<vendor>]`; env resolves ahead of
      -- config.toml, which is what lets a utility call be fenced without touching the user's
      -- persistent configuration.
      local env = grok_lightweight.apply_env({})
      for _, vendor in ipairs({ "CLAUDE", "CURSOR" }) do
        for _, cell in ipairs({ "RULES", "AGENTS", "SKILLS", "HOOKS" }) do
          assert.equals("0", env[string.format("GROK_%s_%s_ENABLED", vendor, cell)])
        end
      end
    end)

    it("does not set the mcps cell, which grok honours in `inspect` and not in the run", function()
      -- Measured against grok 0.2.101: with GROK_CLAUDE_MCPS_ENABLED=0 every server is reported
      -- `[disabled]` by `grok inspect`, and the run still handshakes all eight and still
      -- advertises the same tool count. Setting it would read as closing #588's second gap while
      -- closing nothing -- the `-c mcp_servers={}` mistake of #574. `--deny "MCPTool(*)"` is what
      -- actually stands there.
      local env = grok_lightweight.apply_env({})
      assert.is_nil(env.GROK_CLAUDE_MCPS_ENABLED)
      assert.is_nil(env.GROK_CURSOR_MCPS_ENABLED)
    end)

    it("disables cross-session memory and subagents", function()
      local env = grok_lightweight.apply_env({})
      assert.equals("0", env.GROK_MEMORY)
      assert.equals("0", env.GROK_SUBAGENTS)
    end)

    it("writes into the environment it was handed rather than replacing it", function()
      local env = { PATH = "/usr/bin", VIBING_HANDLE_ID = "h1" }
      grok_lightweight.apply_env(env)
      assert.equals("/usr/bin", env.PATH)
      assert.equals("h1", env.VIBING_HANDLE_ID)
    end)
  end)

  describe("resolve_cwd", function()
    it("runs a lightweight call from an empty directory outside the project", function()
      local cwd = grok_lightweight.resolve_cwd({ lightweight = true, cwd = "/repo" })
      assert.equals(cache_root .. "/vibing/grok-lightweight", cwd)
      assert.equals(1, vim.fn.isdirectory(cwd))
      assert.same({}, vim.fn.readdir(cwd))
    end)

    it("leaves an ordinary call in the chat's working directory", function()
      assert.equals("/repo", grok_lightweight.resolve_cwd({ cwd = "/repo" }))
      assert.is_nil(grok_lightweight.resolve_cwd({}))
    end)

    it("falls back to the ordinary directory when the scratch one cannot be created", function()
      -- A title generation that dies because a cache directory was unwritable would be a worse
      -- trade than one that reads a CLAUDE.md it did not need.
      vim.fn.stdpath = function(what)
        if what == "cache" then
          return "/dev/null/not-a-directory"
        end
        return original_stdpath(what)
      end
      assert.equals("/repo", grok_lightweight.resolve_cwd({ lightweight = true, cwd = "/repo" }))
    end)

    it("resolves the scratch directory once per process", function()
      local first = grok_lightweight.resolve_cwd({ lightweight = true })
      vim.fn.stdpath = function()
        error("stdpath must not be consulted again")
      end
      assert.equals(first, grok_lightweight.resolve_cwd({ lightweight = true }))
    end)
  end)
end)
