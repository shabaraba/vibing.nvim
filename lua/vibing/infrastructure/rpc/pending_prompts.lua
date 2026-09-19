--- The two registries of "a prompt is holding this turn open", asked as one thing (#778, #788).
---
--- `pending_approvals` withholds a `<request_id>.res` file a shell hook is polling;
--- `pending_questions` withholds the reply to an MCP tool call the CLI is blocked awaiting. They
--- stay separate modules because what is withheld differs — but **every exit owes both of them**,
--- and `.claude/rules/permissions.md` names the failure that follows from forgetting it: merging
--- the drawing while leaving the lifetimes split is how the two silently drift.
---
--- So the ways out are reached through here rather than through each registry by hand. A caller
--- that names one module is a caller that can be given an exit covering only one channel — and the
--- two halves fail differently enough that the gap is invisible from either side: a forgotten
--- approval spins its hook to the script's own deadline, a forgotten question sits until the CLI's
--- own MCP idle timeout (1800s on claude) with the chat looking alive throughout.
--- @module vibing.infrastructure.rpc.pending_prompts

local M = {}

local CHANNELS = {
  { noun = "approval", module = "pending_approvals" },
  { noun = "question", module = "pending_questions" },
}

--- The reason each registry is given is the same sentence with a different noun, so callers hand
--- over a template rather than two strings — there is no exit where an approval and a question
--- stopped being waited on for different reasons.
--- @param template string containing one `%s`, filled with `approval` / `question`
--- @param resolve fun(registry: table, reason: string): number
--- @return number released
local function both(template, resolve)
  local released = 0
  for _, channel in ipairs(CHANNELS) do
    -- Guarded per registry: one throwing must not take the other one's release with it, which is
    -- the whole reason the two live behind one call.
    pcall(function()
      local registry = require("vibing.infrastructure.rpc." .. channel.module)
      released = released + resolve(registry, string.format(template, channel.noun))
    end)
  end
  return released
end

--- Whether anything at all is still waiting for an answer from this chat.
---
--- Asked of the **registries**, never of the rendered lists: `_pending_approvals` and
--- `_pending_choices` are drawing state and deliberately outlive an answer, so a chat whose turn
--- was killed keeps its lines and holds nothing.
--- @param chat_bufnr number
--- @return boolean
function M.has_for_chat(chat_bufnr)
  return require("vibing.infrastructure.rpc.pending_approvals").has_for_chat(chat_bufnr)
    or require("vibing.infrastructure.rpc.pending_questions").has_for_chat(chat_bufnr)
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
