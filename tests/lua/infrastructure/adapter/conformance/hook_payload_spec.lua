---@diagnostic disable: undefined-field
--- Contract C9 of ADR 009: a tool call reaches the permission rules under its canonical name with
--- its path under `file_path`, whichever CLI's hook payload it arrived in.
---
--- Each payload below was read off that CLI's own PreToolUse hook, at the version named beside it,
--- for a shell command and for the tool that carries a path -- the two calls the granular rules
--- care most about. The handler's own normalisation is what runs, so a vocabulary whose three steps
--- fall out of order fails here rather than in a chat.
---
--- `tests/fixtures/streams/README.md` describes the capture: the same run that produced the stream
--- fixtures, with the hook installed through its real transport and answered by a stand-in RPC
--- server, so these are the bytes the CLI sent rather than a reading of its documentation.
local Agents = require("vibing.core.constants.agents")
local permission = require("vibing.infrastructure.rpc.handlers.permission")

--- Per backend: the path-carrying call and the shell call, plus any superseded shape still worth
--- accepting. `canonical` names the expected tool when it is not `Edit`.
local PAYLOADS = {
  -- claude 2.1.236: the canonical shape, snake_case, nothing to translate.
  claude = {
    edit = { tool_name = "Edit", tool_input = { file_path = "lua/a.lua", old_string = "a", new_string = "b" } },
    shell = { tool_name = "Bash", tool_input = { command = "ls" } },
  },
  -- codex 0.154.0: shell-likes already arrive as `Bash`. An edit arrives as `apply_patch` with the
  -- paths inside the patch envelope in `command` and no path field at all, so it cannot stand in
  -- for the path case (`codex_tool_vocabulary.lua` says why that is left so); `view_image` is the
  -- codex call whose path is liftable.
  codex = {
    edit = { tool_name = "view_image", tool_input = { path = "lua/a.lua" }, canonical = "Read" },
    shell = { tool_name = "Bash", tool_input = { command = "ls" } },
  },
  -- copilot 1.0.80: camelCase keys with the arguments as an object. 1.0.78 sent those same fields
  -- as a JSON string, which `superseded` keeps accepted -- the vocabulary takes either.
  copilot = {
    edit = { toolName = "edit", toolArgs = { path = "lua/a.lua", old_str = "a", new_str = "b" } },
    shell = { toolName = "bash", toolArgs = { command = "ls" } },
    superseded = {
      edit = { toolName = "edit", toolArgs = '{"path":"lua/a.lua","old_str":"a","new_str":"b"}' },
      shell = { toolName = "bash", toolArgs = '{"command":"ls"}' },
    },
  },
  -- grok 0.2.101: camelCase keys with the arguments as a table. `read_file` is the path case
  -- because it names the path `target_file`, which is what `PATH_KEYS` exists to lift; grok's own
  -- editing tool (`search_replace`) already sends `file_path` and needs no translation.
  grok = {
    edit = { toolName = "read_file", toolInput = { target_file = "lua/a.lua" }, canonical = "Read" },
    shell = { toolName = "run_terminal_command", toolInput = { command = "ls" } },
  },
}

--- @param payload table
--- @param descriptor table
--- @param expected_name string
local function assert_path_call(payload, descriptor, expected_name)
  local name, input = permission.normalize_hook_input(vim.deepcopy(payload), descriptor.vocabulary)
  assert.equals(expected_name, name)
  assert.equals("lua/a.lua", input.file_path)
end

--- @param payload table
--- @param descriptor table
local function assert_shell_call(payload, descriptor)
  local name, input = permission.normalize_hook_input(vim.deepcopy(payload), descriptor.vocabulary)
  assert.equals("Bash", name)
  assert.equals("ls", input.command)
end

describe("conformance: hook payload normalisation", function()
  for _, def in ipairs(Agents.list()) do
    local descriptor = require(def.descriptor_module)
    local payloads = PAYLOADS[def.id]

    describe(def.id, function()
      it("has a recorded payload shape", function()
        assert.is_table(payloads, def.id .. " has no captured hook payload in this spec")
      end)

      it("brings a file path to its canonical name with file_path set", function()
        assert_path_call(payloads.edit, descriptor, payloads.edit.canonical or "Edit")
      end)

      it("brings a shell command to Bash with the command intact", function()
        assert_shell_call(payloads.shell, descriptor)
      end)

      -- A CLI that changed its payload shape is still read: an install pinned to the older version
      -- must not lose its permission gate because a newer one was captured here.
      if payloads.superseded then
        it("still reads the shape an older release of this CLI sent", function()
          assert_path_call(payloads.superseded.edit, descriptor, payloads.superseded.edit.canonical or "Edit")
          assert_shell_call(payloads.superseded.shell, descriptor)
        end)
      end
    end)
  end
end)
