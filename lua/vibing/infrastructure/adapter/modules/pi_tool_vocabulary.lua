--- The Pi coding agent's tool names and input shape, translated to the canonical vocabulary the
--- rest of vibing.nvim speaks.
---
--- Unlike the other backends, the payload this reads is one vibing.nvim writes itself
--- (`pi-extension/src/index.ts`), because Pi has no external-process hook to capture one from. That
--- makes the two files a pair: the extension sends Pi's own event verbatim, and the translation
--- lives here, where the Lua side can see it. Sending claude's spelling from the extension would
--- make this module inert and move the mapping somewhere `permission.lua` cannot reach.
--- @module vibing.infrastructure.adapter.modules.pi_tool_vocabulary

local M = {}

--- Read off Pi 0.87.1's own tool schemas (`dist/core/tools/*.js`) and confirmed against a captured
--- `tool_call` event, not inferred from its documentation. `pi --help` lists exactly these eight as
--- the built-in set.
---
--- `ls` and `find` both become `Glob`: vibing's canonical vocabulary has no directory-listing tool,
--- and `Glob` is the read-only file-enumeration entry `ALWAYS_ALLOWED_TOOLS` already covers, which
--- is what these two are. Grok maps its `list_dir` the same way.
---
--- `powershell` is Pi's Windows sibling of `bash` — same schema, same risk — so it must reach the
--- same rules. Left unmapped it would arrive at `can_use_tool` as the literal `powershell`, match
--- nothing in `permissions.allow`, and resolve to `ask` while every `Bash(...)` deny rule the user
--- wrote missed it entirely.
--- @type table<string, string>
local NATIVE_TO_CANONICAL = {
  bash = "Bash",
  powershell = "Bash",
  read = "Read",
  edit = "Edit",
  write = "Write",
  grep = "Grep",
  find = "Glob",
  ls = "Glob",
}

--- Where Pi puts the path a tool is about. One key across every file tool (`read`, `edit`, `write`,
--- and optionally `grep` / `find` / `ls`), which is unusually tidy — grok needs three. Granular
--- permission rules read `file_path`, so a `paths` rule would silently never match a Pi tool
--- without this.
--- @type string[]
local PATH_KEYS = { "path" }

--- @param native_tool_name string
--- @return string|nil canonical name, or nil when there is no mapping
function M.to_canonical(native_tool_name)
  return NATIVE_TO_CANONICAL[native_tool_name]
end

--- Pi's `tool_call` event names its fields `toolName` and `input`:
---
---   {"hookEventName":"PreToolUse","toolName":"bash","input":{"command":"ls"},"toolCallId":"..."}
---
--- Note `input`, not grok's `toolInput`. Read straight through, the handler sees a nil `tool_name`,
--- every granular rule misses, and `to_canonical` is handed an empty string — so the whole
--- vocabulary would silently do nothing and the first tool call of every turn would stall until the
--- extension's own deadline denied it.
--- @param hook_input table Raw decoded payload
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
    tool_input = hook_input.input or {},
  })
end

--- @param tool_input table
--- @return table input with `file_path` filled in when Pi named it something else. The original is
---   never mutated: the payload is also used to render the approval UI.
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
