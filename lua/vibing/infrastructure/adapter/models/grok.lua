--- Which models the Grok CLI would accept, asked of the CLI and spending no tokens.
---
--- `grok models` prints the list and exits. Measured against grok 1.0.34: 660ms, and it answers
--- **while logged out** -- "You are not authenticated." is printed above the list rather than
--- instead of it -- so a user who has not logged in still gets the real names.
---
---     You are not authenticated.
---
---     Default model: grok-4.6
---
---     Available models:
---       * grok-4.6 (default)
---       - grok-4.5
---
--- All of it on stdout, with stderr empty and the exit code 0 (measured by redirecting the two
--- streams to separate files; `grok models 2>&1 >/dev/null` reads the opposite way round).
--- @module vibing.infrastructure.adapter.models.grok

local M = {}

--- @param config Vibing.Config|nil
--- @return string[]
function M.command(config)
  -- `grok_command_builder.BINARY.resolve` is deliberately not reused: it raises when the CLI is
  -- missing, and it sniffs the binary for officialness with two **blocking** `vim.fn.system`
  -- calls, which is what that module's own comment warns about paying per request. This runs on
  -- the completion path. What is kept is the half a user can change -- the configured executable.
  local configured = vim.tbl_get(config or {}, "backends", "grok", "executable")
  if type(configured) == "string" and configured ~= "" and configured ~= "auto" then
    return { configured, "models" }
  end
  return { "grok", "models" }
end

--- @param stdout string
--- @return Vibing.AgentModelCandidate[]
function M.parse(stdout)
  local candidates = {}

  for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
    -- Only the bulleted lines. "Default model: grok-4.6" names a model too, and reading it as an
    -- entry lists the default twice.
    local value = line:match("^%s*[%*%-]%s+(%S+)")
    if value then
      -- The CLI gives no per-model description, and repeating the name as one makes the popup
      -- read "grok-4.5 / grok-4.5"; the one thing it does say is which model is the default.
      local is_default = line:find("(default)", 1, true) ~= nil
      table.insert(candidates, {
        value = value,
        description = is_default and "Grok CLI default model" or "Available in the Grok CLI",
      })
    end
  end

  return candidates
end

return M
