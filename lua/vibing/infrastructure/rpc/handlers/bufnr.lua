--- Shared buffer-argument handling for RPC handlers.
--- @module vibing.infrastructure.rpc.handlers.bufnr

local M = {}

--- Whether an optional RPC argument was actually supplied.
---
--- `vim.json.decode` turns a JSON `null` into `vim.NIL`, which is neither `nil` nor falsy — so a
--- caller that spells an unused optional argument as `null` (a habit models have) would otherwise
--- read as having supplied it, and get "pass either bufnr or file_path, not both" for a call that
--- named its target exactly once.
--- @param value any
--- @return any|nil
local function present(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

--- Turn an incoming bufnr argument into a real buffer number.
---
--- Errors rather than defaulting when the caller gave nothing: the tools that use this change what
--- the user sees, so guessing a buffer is worse than refusing.
--- @param bufnr any
--- @return number
function M.resolve(bufnr)
  if type(bufnr) ~= "number" then
    error("Missing bufnr parameter")
  end
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

--- Decide which buffer a tool that accepts `bufnr` **or** `file_path` is aimed at.
---
--- `file_path` exists because a bufnr is only meaningful inside the Neovim session that issued
--- it, while the chat file path is what frontmatter records and what survives a restart (#641).
--- A path that names no open chat is opened here rather than refused.
---
--- It names a **chat file** and nothing else, which is why this is not the generic path argument
--- its name might suggest: `chat_locator.open` attaches a chat buffer, and a path that reaches
--- `send_message` gets a `## User` written into it. `nvim_load_buffer` remains the way to reach
--- an ordinary file.
---
--- Returns nil when neither was given, leaving "no argument" for the caller to interpret: reading
--- a buffer can sensibly fall back to the current one, sending a message cannot.
--- @param params table?
--- @return number|string|nil bufnr
function M.resolve_chat_target(params)
  params = params or {}
  local bufnr, file_path = present(params.bufnr), present(params.file_path)

  -- Refuse rather than pick. Both arguments arriving is a sign the caller is confused about which
  -- chat it means, and quietly preferring one of them sends to a chat it did not intend without
  -- anything saying so.
  if bufnr ~= nil and file_path ~= nil then
    error("Pass either bufnr or file_path, not both")
  end

  if file_path ~= nil then
    return require("vibing.application.chat.chat_locator").open(file_path)
  end

  if bufnr == nil then
    return nil
  end
  if type(bufnr) ~= "number" then
    error("bufnr must be a number")
  end

  -- Deliberately **not** `M.resolve`, which maps 0 to the current buffer. That is right for the
  -- annotation and highlight tools, and wrong here: a send appends a `## User` and starts a turn,
  -- so reading 0 as "whichever chat the user is sitting in" is the same "delivers into a chat
  -- nobody intended" failure the both-arguments refusal above exists to prevent. Handed through
  -- unchanged, 0 keeps meaning the current buffer to `nvim_buf_get_lines` — which is what
  -- `nvim_get_buffer` advertises — while `view.get_chat_buffer(0)` still refuses the send.
  return bufnr
end

--- Validate an optional `from_bufnr` argument — the calling chat's own buffer number.
---
--- Absent (nil / JSON `null`) stays fine: the orchestration link is optional by design, and a
--- forgotten argument must not refuse the call (version skew, older MCP servers). But a value
--- that is present and names no chat buffer is an error rather than a warning. The typical way
--- to get here is a number carried over from before a Neovim restart; proceeding would drop the
--- `orchestrated`/`orchestrated_by` link and the completion subscription in silence, while the
--- MCP caller — the one party able to correct the number — is told the call succeeded (#661).
--- @param value any
--- @return number|nil
function M.resolve_from_bufnr(value)
  value = present(value)
  if value == nil then
    return nil
  end
  if type(value) ~= "number" then
    error("from_bufnr must be a number")
  end
  if
    not (
      vim.api.nvim_buf_is_valid(value)
      and require("vibing.presentation.chat.view").get_chat_buffer(value) ~= nil
    )
  then
    error(
      string.format(
        "from_bufnr %d does not name a chat buffer in this Neovim session "
          .. "(buffer numbers do not survive a restart). Pass the exact chat buffer number "
          .. "from your current system prompt, or omit from_bufnr",
        value
      )
    )
  end
  return value
end

return M
