--- The Command Code CLI's tool names and input shape, translated to the canonical vocabulary.
---
--- Two callers share this table, which is why both spellings live in it: the **mod bridge**
--- (`--mod`, the oneshot and duplex gate) forwards the CLI's own wire payload, whose names are the
--- snake_case ids the model calls (`shell_command`, `read_file`); the **ACP transport** carries no
--- native name at all — a `tool_call` has only a prose `title` and a coarse `kind` — so the decoder
--- hands the kind through and this table maps it. A tool must be called the same thing in the chat
--- and in a rule, so both spellings resolve to the same canonical name.
--- @module vibing.infrastructure.adapter.modules.commandcode_tool_vocabulary

local tools_constants = require("vibing.core.constants.tools")

local M = {}

--- Native ids the CLI's tools are called by, as measured on its own PreToolUse payload
--- (`tool_name`) and stream (`tool_use.name`).
local NATIVE_TO_CANONICAL = {
  read_file = "Read",
  write_file = "Write",
  edit_file = "Edit",
  shell_command = "Bash",
  run_command = "Bash",
  glob = "Glob",
  grep = "Grep",
  web_fetch = "WebFetch",
  web_search = "WebSearch",
  todo_write = "TodoWrite",
  task = "Task",
  agent = "Task",
  skill = "Skill",
  ask_user_question = "AskUserQuestion",
}

--- The ACP `tool_call.kind` values, mapped to the canonical tool they stand for. Every update
--- carries one; `title` is prose for a human ("Shell: echo hi") and cannot be matched against a
--- rule, so this — not the title — is what the duplex renderer names a call by.
local ACP_KIND_TO_CANONICAL = {
  read = "Read",
  edit = "Edit",
  execute = "Bash",
  search = "Grep",
  fetch = "WebFetch",
}

--- @param native_tool_name string
--- @return string|nil canonical, nil when this name belongs to neither vocabulary
function M.to_canonical(native_tool_name)
  if type(native_tool_name) ~= "string" then
    return nil
  end
  if NATIVE_TO_CANONICAL[native_tool_name] then
    return NATIVE_TO_CANONICAL[native_tool_name]
  end
  if ACP_KIND_TO_CANONICAL[native_tool_name] then
    return ACP_KIND_TO_CANONICAL[native_tool_name]
  end
  -- An MCP tool arrives already namespaced (`mcp__server__tool`); passing it through keeps it
  -- matchable by a `mcp__` rule without inventing a canonical name for it.
  if native_tool_name:match("^mcp__") then
    return native_tool_name
  end
  return nil
end

--- The CLI's own wire keys into the ones the handler reads.
---
--- The mod bridge forwards the CLI's PreToolUse payload, which is already Claude-shaped
--- (`tool_name` / `tool_input`), so this is normally the identity. It accepts the camelCase
--- spelling as well because both forms were observed while measuring, and dropping one would turn
--- a payload the CLI changed into a rule that silently never matches.
--- @param hook_input table
--- @return table
function M.normalize_payload(hook_input)
  if type(hook_input) ~= "table" or hook_input.tool_name ~= nil then
    return hook_input
  end
  if hook_input.toolName == nil then
    return hook_input
  end
  return vim.tbl_extend("force", hook_input, {
    tool_name = hook_input.toolName,
    tool_input = hook_input.toolInput or hook_input.input or {},
  })
end

--- @param tool_input table
--- @param tool_name string|nil canonical (`normalize_input` runs after `to_canonical`)
--- @return table
function M.normalize_input(tool_input, tool_name)
  if type(tool_input) ~= "table" then
    return tool_input
  end
  local normalized = tool_input
  local changed = false
  local function copy()
    if not changed then
      normalized = vim.tbl_extend("force", {}, tool_input)
      changed = true
    end
    return normalized
  end

  -- Command Code splits a shell invocation across `command` and `args` (`{"command":"echo",
  -- "args":["hi"]}`), where every other backend sends one command line. The granular rules match
  -- the whole line, so it is rebuilt here; without it a `Bash(git push:*)` rule would see only
  -- `git` and a rule naming the arguments would never match.
  if tool_name == "Bash" and type(tool_input.args) == "table" and #tool_input.args > 0 then
    local parts = { tostring(tool_input.command or "") }
    for _, arg in ipairs(tool_input.args) do
      table.insert(parts, tostring(arg))
    end
    copy().command = table.concat(parts, " ")
  end

  if not tool_input.file_path and tool_input.path then
    copy().file_path = tool_input.path
  end

  if not changed then
    return tool_input
  end
  return normalized
end

--- The CLI's own control tools, which the harness needs to keep working and which touch no file.
--- Matched after name normalisation, the way every backend's predicate is.
--- @param tool_name string canonical
--- @return boolean
function M.is_always_allowed(tool_name)
  if type(tool_name) ~= "string" then
    return false
  end
  if tool_name:lower():find("mcp__", 1, true) then
    return false
  end
  if NATIVE_TO_CANONICAL[tool_name] or ACP_KIND_TO_CANONICAL[tool_name] then
    return false
  end
  if tools_constants.VALID_TOOLS_MAP[tool_name] then
    return false
  end
  return tool_name:match("^task_") ~= nil
    or tool_name == "enter_plan_mode"
    or tool_name == "exit_plan_mode"
    or tool_name == "plan_review"
    or tool_name == "get_diagnostics"
    or tool_name == "vision"
end

return M
