---@diagnostic disable: undefined-field
--- Contract C9 of ADR 009: a tool call reaches the permission rules under its canonical name with
--- its path under `file_path`, whichever CLI's hook payload it arrived in.
---
--- Each payload below is the shape the CLI actually sends (recorded in the vocabulary modules,
--- with the version), for an edit of `lua/a.lua` and a shell command -- the two calls the
--- granular rules care most about. The handler's own normalisation is what runs, so a vocabulary
--- whose three steps fall out of order fails here rather than in a chat.
local Agents = require("vibing.core.constants.agents")
local permission = require("vibing.infrastructure.rpc.handlers.permission")

--- Per backend: { edit = <payload>, shell = <payload> }, or an explicit note of why not.
local PAYLOADS = {
  -- claude 2.1.x: the canonical shape.
  claude = {
    edit = { tool_name = "Edit", tool_input = { file_path = "lua/a.lua", old_string = "a", new_string = "b" } },
    shell = { tool_name = "Bash", tool_input = { command = "ls" } },
  },
  -- codex 0.153.4: apply_patch carries its paths inside the patch envelope, not as a field, so a
  -- `paths` rule cannot match it (codex_tool_vocabulary.lua says why that is left so). The
  -- view_image read is the case whose path is liftable.
  codex = {
    edit = { tool_name = "view_image", tool_input = { path = "lua/a.lua" }, canonical = "Read" },
    shell = { tool_name = "Bash", tool_input = { command = "ls" } },
  },
  -- copilot 1.0.78: camelCase keys with the arguments as a JSON string.
  copilot = {
    edit = { toolName = "edit", toolArgs = '{"path":"lua/a.lua","old_str":"a","new_str":"b"}' },
    shell = { toolName = "bash", toolArgs = '{"command":"ls"}' },
  },
  -- grok 0.2.101: camelCase keys with the arguments as a table.
  grok = {
    edit = { toolName = "search_replace", toolInput = { target_file = "lua/a.lua" } },
    shell = { toolName = "run_terminal_command", toolInput = { command = "ls" } },
  },
}

describe("conformance: hook payload normalisation", function()
  for _, def in ipairs(Agents.list()) do
    local descriptor = require(def.descriptor_module)
    local payloads = PAYLOADS[def.id]

    describe(def.id, function()
      it("has a recorded payload shape", function()
        assert.is_table(payloads, def.id .. " has no captured hook payload in this spec")
      end)

      it("brings a file edit to its canonical name with file_path set", function()
        local name, input = permission.normalize_hook_input(vim.deepcopy(payloads.edit), descriptor.vocabulary)
        assert.equals(payloads.edit.canonical or "Edit", name)
        assert.equals("lua/a.lua", input.file_path)
      end)

      it("brings a shell command to Bash with the command intact", function()
        local name, input = permission.normalize_hook_input(vim.deepcopy(payloads.shell), descriptor.vocabulary)
        assert.equals("Bash", name)
        assert.equals("ls", input.command)
      end)
    end)
  end
end)
