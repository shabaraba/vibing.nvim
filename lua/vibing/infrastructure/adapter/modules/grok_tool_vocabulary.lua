--- Grok Build CLI's tool names and input shape, translated to the canonical vocabulary the rest
--- of vibing.nvim speaks.
---
--- Lives beside the adapter rather than in the permission handler so that shared infrastructure
--- never has to know which backend it is talking to: `grok_cli.lua` hands this module to
--- `set_active_opts` as a generic `_tool_vocabulary`, and the handler just calls whatever it was
--- given. See #516.
--- @module vibing.infrastructure.adapter.modules.grok_tool_vocabulary

local M = {}

--- Confirmed against real PreToolUse payloads and Grok's own Claude-compat matcher aliases, not
--- inferred from its docs.
--- @type table<string, string>
local NATIVE_TO_CANONICAL = {
  run_terminal_command = "Bash",
  bash = "Bash",
  shell = "Bash",
  read_file = "Read",
  write_file = "Write",
  search_replace = "Edit",
  edit_file = "Edit",
  apply_patch = "Edit",
  list_dir = "Glob",
  grep = "Grep",
  web_search = "WebSearch",
  web_fetch = "WebFetch",
  spawn_subagent = "Task",
}

--- Where Grok puts the path a tool is about. Granular permission rules read `file_path` (the
--- Claude convention), so a `paths` rule would silently never match a Grok tool without this.
--- @type string[]
local PATH_KEYS = { "path", "target_file", "filePath" }

--- @param native_tool_name string
--- @return string|nil canonical name, or nil when there is no mapping
function M.to_canonical(native_tool_name)
  return NATIVE_TO_CANONICAL[native_tool_name]
end

--- Grok's PreToolUse payload is camelCase, where Claude's is snake_case:
---
---   {"hookEventName":"pre_tool_use","toolName":"read_file","toolInput":{"target_file":"a.txt"}}
---
--- Verified against grok 0.2.101, not inferred. Without this the handler reads a nil `tool_name`,
--- every granular rule misses, and `to_canonical` below is handed an empty string -- so the whole
--- vocabulary silently does nothing and the first tool call of every turn stalls the hook until it
--- fails closed.
--- @param hook_input table Raw decoded PreToolUse payload
--- @return table payload with `tool_name`/`tool_input` present. Never mutates the original.
function M.normalize_payload(hook_input)
  if type(hook_input) ~= "table" or hook_input.tool_name ~= nil then
    return hook_input
  end
  if hook_input.toolName == nil then
    return hook_input
  end

  return vim.tbl_extend("force", hook_input, {
    tool_name = hook_input.toolName,
    tool_input = hook_input.toolInput or {},
  })
end

--- @param tool_input table
--- @return table input with `file_path` filled in when Grok named it something else. The original
---   is never mutated: the hook payload is also used to render the approval UI.
function M.normalize_input(tool_input)
  if type(tool_input) ~= "table" or tool_input.file_path then
    return tool_input
  end

  for _, key in ipairs(PATH_KEYS) do
    if tool_input[key] then
      return vim.tbl_extend("force", tool_input, { file_path = tool_input[key] })
    end
  end

  return tool_input
end

return M
