---@diagnostic disable: undefined-field
--- Contracts C10 and C11 of ADR 009 at the argv level, for every backend: a lightweight call
--- carries none of the chat's gate or plugins, and every permission mode produces an argv.
---
--- The per-backend spelling of each flag is pinned by that backend's builder spec; what this
--- asserts is what must hold whichever backend a chat is on.
local Agents = require("vibing.core.constants.agents")
local Transports = require("vibing.infrastructure.hooks.transports")
local helper = require("tests.helpers.adapter_stream")

local MODES = { "default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions" }

--- Flags that carry the hook or the plugins into an ordinary turn on some backend. None may
--- appear on a lightweight one.
local GATE_FLAGS = { "--settings", "--plugin-dir", "--dangerously-bypass-hook-trust", "--allowedTools", "--disallowedTools", "--deny-tool" }

describe("conformance: request", function()
  local original_exepath, original_executable

  before_each(function()
    original_exepath = vim.fn.exepath
    original_executable = vim.fn.executable
    local fake = helper.fake_binary("conformance")
    vim.fn.exepath = function()
      return fake
    end
    -- grok sniffs a configured or found binary for officialness; a non-executable path skips it.
    vim.fn.executable = function(path)
      if path == fake then
        return 0
      end
      return original_executable(path)
    end
    helper.reset_path_caches()
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    vim.fn.executable = original_executable
    helper.reset_path_caches()
  end)

  for _, def in ipairs(Agents.list()) do
    local descriptor = require(def.descriptor_module)
    local config = { agent = { default_model = "sonnet", plugins = { self = false, project_dir = false } } }

    describe(def.id, function()
      it("carries no gate flag and no hook reference on a lightweight call, whatever the mode", function()
        -- The hook itself is never installed for a lightweight call (hook_registration_spec), so
        -- a real turn has no hook_arg; passing one anyway proves the request drops it too.
        for _, mode in ipairs(MODES) do
          local cmd = descriptor.build("hi", { lightweight = true, permission_mode = mode }, nil, config, "/tmp/hook-arg")
          for _, flag in ipairs(GATE_FLAGS) do
            assert.is_false(vim.tbl_contains(cmd, flag), string.format("%s lightweight/%s carries %s", def.id, mode, flag))
          end
          assert.is_false(vim.tbl_contains(cmd, "/tmp/hook-arg"), def.id .. " lightweight references the hook")
        end
      end)

      it("references the installed hook on an ordinary call when its transport is argv-visible", function()
        local transport = descriptor.hook.transport
        if transport == "project_dir" then
          -- Discovered from the tree, so nothing to find in the argv.
          return
        end
        local hook_arg = transport == "config_override" and { "-c", "hooks.PreToolUse=[conformance]" } or "/tmp/hook-arg"
        local cmd = descriptor.build("hi", { permission_mode = "default" }, nil, config, hook_arg)
        local needle = type(hook_arg) == "table" and hook_arg[2] or hook_arg
        assert.is_true(vim.tbl_contains(cmd, needle), def.id .. " does not reference its hook")
      end)

      it("builds an argv for every permission mode, fresh and resumed", function()
        for _, mode in ipairs(MODES) do
          local fresh = descriptor.build("hi", { permission_mode = mode }, nil, config, nil)
          local resumed = descriptor.build("hi", { permission_mode = mode }, "sess-1", config, nil)
          assert.is_true(#fresh > 1, def.id .. "/" .. mode)
          assert.is_true(#resumed > #fresh - 1, def.id .. "/" .. mode .. " resumed")
          assert.is_true(vim.tbl_contains(resumed, "sess-1") or vim.tbl_contains(resumed, "--resume=sess-1"), def.id .. " does not resume")
        end
      end)

      it("puts the prompt in the argv exactly once", function()
        local prompt = "conformance-prompt-" .. def.id
        local cmd = descriptor.build(prompt, {}, "sess-1", config, nil)
        local hits = 0
        for _, arg in ipairs(cmd) do
          if arg:find(prompt, 1, true) then
            hits = hits + 1
          end
        end
        assert.equals(1, hits)
      end)

      it("keeps the hook wanted-rules and the request in agreement in bypassPermissions", function()
        -- A backend that drops the hook in bypass must not then reference a hook_arg either.
        if not Transports.wanted(descriptor.hook, { permission_mode = "bypassPermissions" }) then
          local cmd = descriptor.build("hi", { permission_mode = "bypassPermissions" }, nil, config, nil)
          assert.is_false(vim.tbl_contains(cmd, "--plugin-dir"))
        end
      end)
    end)
  end
end)
