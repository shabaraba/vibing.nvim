--- Turning one Codex app-server approval request into the fields the chat prompt already draws.
---
--- The renderer knows `Tool:` / `Command:` / `File:` and a list of indented continuation lines; it
--- does not know codex. So everything codex-shaped is flattened here into `input.details`, whose
--- lines are written with the three-space indent `approval_parser.continues_block` already counts
--- as part of a prompt block. **That is why no new `FIELD_PREFIXES` entry is needed**, and adding
--- one instead would widen what `strip_prompt_lines` eats out of the user's own prose.
---
--- Field names are measured against codex-cli 0.160.1:
---
---   item/commandExecution/requestApproval  command, cwd, reason, commandActions, availableDecisions
---   item/fileChange/requestApproval        itemId, reason, grantRoot — and **nothing else**
---
--- The second one is the awkward case: its params carry neither a path nor a diff. Those live in
--- the `item/started` notification codex sent just before it, under the same `itemId`, which is why
--- `describe` takes the changes as an argument rather than digging for them.
--- @module vibing.infrastructure.adapter.modules.codex_native_request

local M = {}

--- How many diff lines a prompt shows before it stops. A prompt is something a human reads before
--- answering; a 400-line patch pushed into the unsent section is one they scroll past instead.
local MAX_DIFF_LINES = 24

--- The server→client methods this plugin answers with a decision.
---
--- `item/permissions/requestApproval` is deliberately **not** here. Its reply is not a decision at
--- all — the response struct carries `permissions` / `scope` / `strict_auto_review`, i.e. a grant
--- being negotiated — so answering it with `{ decision = ... }` would be inventing a protocol.
--- It keeps the `-32601` every unhandled request gets.
--- @type table<string, "command"|"file_change">
M.METHODS = {
  ["item/commandExecution/requestApproval"] = "command",
  ["item/fileChange/requestApproval"] = "file_change",
  -- The pre-`item/*` spellings. Still in the 0.160.1 binary's request enum, never observed in a
  -- run; answered the same way because their response struct is the same single `decision` field.
  ["execCommandApproval"] = "command",
  ["applyPatchApproval"] = "file_change",
}

--- @param details string[]
--- @param text any
local function detail(details, text)
  if type(text) == "string" and text ~= "" then
    table.insert(details, text)
  end
end

--- @param details string[]
--- @param diff any
local function diff_lines(details, diff)
  if type(diff) ~= "string" or diff == "" then
    return
  end
  local shown = 0
  for line in diff:gmatch("[^\n]+") do
    if shown >= MAX_DIFF_LINES then
      table.insert(details, "… (diff truncated)")
      return
    end
    table.insert(details, line)
    shown = shown + 1
  end
end

--- @param params table
--- @return string tool, table input
local function describe_command(params)
  local details = {}
  detail(details, params.cwd and ("in " .. tostring(params.cwd)))
  detail(details, params.reason and tostring(params.reason))
  return "Codex command execution", {
    command = type(params.command) == "string" and params.command or nil,
    details = details,
  }
end

--- @param params table
--- @param changes table[]|nil what `item/started` carried for this `itemId`
--- @return string tool, table input
local function describe_file_change(params, changes)
  local details, first_path = {}, nil
  -- `fileChanges` is the legacy method's own field; the modern one has nothing and is handed the
  -- changes from the item it belongs to.
  local list = changes or (type(params.fileChanges) == "table" and params.fileChanges) or {}
  for _, change in ipairs(list) do
    if type(change) == "table" then
      local path = type(change.path) == "string" and change.path or nil
      local kind = type(change.kind) == "table" and change.kind.type or change.kind
      first_path = first_path or path
      detail(details, path and ((kind and (tostring(kind) .. " ") or "") .. path))
      diff_lines(details, change.diff)
    end
  end
  detail(details, params.reason and tostring(params.reason))
  detail(details, params.grantRoot and ("grant root: " .. tostring(params.grantRoot)))
  if #details == 0 then
    detail(details, "Codex did not say which files this changes.")
  end
  return "Codex file change", { file_path = first_path, details = details }
end

--- What the chat should show for this request.
--- @param method string
--- @param params table|nil
--- @param changes table[]|nil the `item/started` changes for `params.itemId`, when known
--- @return string tool, table input
function M.describe(method, params, changes)
  params = type(params) == "table" and params or {}
  if M.METHODS[method] == "file_change" then
    return describe_file_change(params, changes)
  end
  return describe_command(params)
end

return M
