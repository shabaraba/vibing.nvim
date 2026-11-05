--- Turning the input claude's gate asked about into the fields the chat prompt draws.
---
--- **The input is the model's, so it is rebuilt, never forwarded.** A native prompt's `input` is
--- trusted in two places that assume vibing wrote it: the renderer iterates `details`, and
--- `approval_delegate` reads `scope_tool` as the tool a delegated scope is checked against. Passing
--- the CLI's payload through let a tool call choose its own scope and, with a string `details`,
--- throw inside the draw while the request sat registered and waiting.
---
--- What is copied is what the renderer and `matchers.lua` read — `command`, `file_path`,
--- `pattern`, `url` — and only as strings. The edit itself goes into `details`, capped the way
--- `codex_native_request` caps a diff, because the question was asked so a human can judge it.
--- @module vibing.infrastructure.rpc.permission_prompt_request

local M = {}

local SHOWN_FIELDS = { "command", "file_path", "pattern", "url" }

--- `Edit` / `Write` / `MultiEdit` keep the change under these names; each is shown under its own label.
local BODY_FIELDS = { "old_string", "new_string", "content" }

M.MAX_BODY_LINES = 24

--- @param details string[]
--- @param label string
--- @param text string
local function body_lines(details, label, text)
  table.insert(details, label .. ":")
  local shown = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if shown >= M.MAX_BODY_LINES then
      table.insert(details, "  … (truncated)")
      return
    end
    -- The prompt is drawn into the unsent section, where `<!-- vibing:req=... -->` is what makes a
    -- line an answer. A body that carries one must not become an answer nobody gave.
    table.insert(details, "  " .. (line:gsub("<!%-%-", "<! --")))
    shown = shown + 1
  end
end

--- @param input any the tool input as the CLI sent it
--- @return table input only the fields vibing draws and matches on
function M.describe(input)
  input = type(input) == "table" and input or {}
  local shown = {}
  for _, key in ipairs(SHOWN_FIELDS) do
    if type(input[key]) == "string" then
      shown[key] = input[key]
    end
  end

  local details = { "claude's own gate asked about this call; vibing's permissions had let it through." }
  for _, key in ipairs(BODY_FIELDS) do
    if type(input[key]) == "string" then
      body_lines(details, key, input[key])
    end
  end
  shown.details = details
  return shown
end

return M
