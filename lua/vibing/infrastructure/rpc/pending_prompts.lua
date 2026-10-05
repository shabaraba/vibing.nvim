--- "A prompt is holding this turn open", asked as one thing (#778).
---
--- One channel today: `pending_approvals`, which withholds a `<request_id>.res` file a shell hook
--- is polling. A second channel used to live here — `pending_questions`, the withheld reply to the
--- `nvim_ask_user_question` MCP call — and was removed when a question became a block the model
--- writes at the end of its turn (`presentation/chat/modules/question_block.lua`): a question no
--- longer holds a turn open, so there is nothing to withhold.
---
--- The exits still go through here rather than through the registry by hand, so a channel added
--- later is covered by every exit at once: `.claude/rules/permissions.md` names the failure of an
--- exit that covers only one channel — the prompt spins to its own deadline with the chat looking
--- alive throughout.
--- @module vibing.infrastructure.rpc.pending_prompts

local M = {}

local CHANNELS = {
  { noun = "approval", module = "pending_approvals" },
}

--- The reason each registry is given is the same sentence with that channel's noun, so callers
--- hand over a template rather than one string per channel.
--- @param template string containing one `%s`, filled with the channel's noun (`approval`)
--- @param resolve fun(registry: table, reason: string): number
--- @return number released
local function both(template, resolve)
  local released = 0
  for _, channel in ipairs(CHANNELS) do
    -- Guarded per registry: one throwing must not take another one's release with it.
    pcall(function()
      local registry = require("vibing.infrastructure.rpc." .. channel.module)
      released = released + resolve(registry, string.format(template, channel.noun))
    end)
  end
  return released
end

--- Whether anything at all is still waiting for an answer from this chat.
---
--- Asked of the **registries**, never of the rendered lists: `_pending_approvals` is drawing state
--- and deliberately outlives an answer, so a chat whose turn was killed keeps its lines and holds
--- nothing.
--- @param chat_bufnr number
--- @return boolean
function M.has_for_chat(chat_bufnr)
  for _, channel in ipairs(CHANNELS) do
    if require("vibing.infrastructure.rpc." .. channel.module).has_for_chat(chat_bufnr) then
      return true
    end
  end
  return false
end

--- Answer everything this chat is holding, with nobody's answer.
--- @param chat_bufnr number
--- @param template string e.g. `"The turn this %s belonged to was cancelled."`
--- @return number released
function M.resolve_for_chat(chat_bufnr, template)
  return both(template, function(registry, reason)
    return registry.resolve_for_chat(chat_bufnr, reason)
  end)
end

--- Answer everything waiting anywhere. Neovim exiting leaves nobody to answer.
---
--- Must run **before** the CLI processes are cancelled: a killed CLI can no longer be the thing
--- that stops waiting.
--- @param template string e.g. `"Neovim exited while this %s was waiting for an answer."`
--- @return number released
function M.resolve_all(template)
  return both(template, function(registry, reason)
    return registry.resolve_all(reason)
  end)
end

return M
