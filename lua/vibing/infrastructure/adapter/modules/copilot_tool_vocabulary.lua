--- Copilot.s tool vocabulary: its own tool names and permission-rule syntax, in one place instead
--- of spread across the display, permission and command-building code, where the two directions
--- had already drifted from each other. See architecture.md.
--- @module vibing.infrastructure.adapter.modules.copilot_tool_vocabulary

local M = {}

--- Copilot's native tool names → the canonical vocabulary (`tools.lua`) that `ui.tool_markers`
--- and `permissions_*` are written in.
--- @type table<string, string>
local NATIVE_TO_CANONICAL = {
  bash = "Bash",
  powershell = "Bash",
  view = "Read",
  create = "Write",
  edit = "Edit",
  glob = "Glob",
  grep = "Grep",
  rg = "Grep",
  web_search = "WebSearch",
  web_fetch = "WebFetch",
  task = "Task",
}

--- Where copilot puts the path a tool is about. Granular permission rules read `file_path` (the
--- Claude convention), so a `paths` rule would never match a copilot tool without this.
--- `file_path` itself is deliberately absent: an input that already has it is returned untouched.
--- @type string[]
local PATH_KEYS = { "path", "filePath" }

--- @param native_tool_name string
--- @return string|nil canonical name, or nil when there is no mapping
function M.to_canonical(native_tool_name)
  return NATIVE_TO_CANONICAL[native_tool_name]
end

--- Copilot's preToolUse payload is camelCase, and its arguments arrive as a JSON *string* rather
--- than an object:
---
---   {"sessionId":"…","cwd":"…","toolName":"bash","toolArgs":"{\"command\":\"echo hi\"}"}
---
--- Captured from copilot 1.0.78, not inferred from its docs. Without this the permission handler
--- reads a nil tool name, so every rule misses and the turn stalls until the hook fails closed.
--- @param hook_input table Raw decoded preToolUse payload
--- @return table payload with `tool_name`/`tool_input` present. Never mutates the original.
function M.normalize_payload(hook_input)
  if type(hook_input) ~= "table" or hook_input.tool_name ~= nil or hook_input.toolName == nil then
    return hook_input
  end

  local args = hook_input.toolArgs
  if type(args) == "string" then
    local ok, decoded = pcall(vim.json.decode, args)
    args = ok and decoded or nil
  end

  return vim.tbl_extend("force", hook_input, {
    tool_name = hook_input.toolName,
    tool_input = type(args) == "table" and args or {},
  })
end

--- @param tool_input table
--- @return table input with `file_path` filled in when copilot named it something else. The
---   original is never mutated: the same payload is also used to render the approval UI.
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

--- Map a vibing permission entry to a copilot permission pattern
--- The bare kind name matches every invocation of that kind; empty parens ("shell()")
--- are rejected by the CLI as an invalid rule format.
--- @param entry string
--- @return string|nil
function M.to_deny_pattern(entry)
  local bash_pattern = entry:match("^Bash%((.+)%)$")
  if bash_pattern then
    return string.format("shell(%s)", bash_pattern)
  end
  if entry == "Bash" then
    return "shell"
  end
  if entry == "Write" or entry == "Edit" then
    return "write"
  end
  if entry == "WebFetch" or entry == "WebSearch" then
    return "url"
  end
  return nil
end

--- Entries already reported as unsupported, so a repeated request does not re-warn.
--- @type table<string, boolean>
local warned_unmapped = {}

--- Reset the unsupported-deny-entry warning state. Test seam only.
function M._reset_unmapped_warnings()
  warned_unmapped = {}
end

--- Convert a deny list into deduplicated copilot patterns, preserving input order.
--- Entries copilot has no permission pattern for are dropped, and warned about once each —
--- silently ignoring them would leave the user believing a tool is blocked when it is not.
--- @param deny string[]|nil
--- @return string[]
function M.build_deny_patterns(deny)
  local patterns, seen = {}, {}
  local unmapped = {}

  for _, entry in ipairs(deny or {}) do
    local pattern = M.to_deny_pattern(entry)
    if pattern then
      if not seen[pattern] then
        seen[pattern] = true
        table.insert(patterns, pattern)
      end
    elseif not warned_unmapped[entry] then
      warned_unmapped[entry] = true
      table.insert(unmapped, entry)
    end
  end

  if #unmapped > 0 then
    vim.notify(
      string.format(
        "[vibing] copilot has no deny pattern for %s; %s will not be blocked",
        table.concat(unmapped, ", "),
        #unmapped == 1 and "it" or "they"
      ),
      vim.log.levels.WARN
    )
  end

  return patterns
end

return M
