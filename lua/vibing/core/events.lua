---The one place `VibingResponseDone` is fired and subscribed to.
---
---**Whether a throwing subscriber costs the ones behind it depends on where the event was fired
---from**, and no subscriber can see that. Measured (`tests/lua/core/events_spec.lua` pins both
---halves): fired from Lua -- which is what `emit_response_done` does, from a `vim.schedule` --
---Neovim reports the error and carries on down the chain; fired from a Vim command context
---(`:doautocmd`, or a `:lua` chunk) it abandons the rest.
---
---The subscribers to a finished turn are unrelated to each other -- folding, the completion
---watchdog, the delivery queue, auto-compact -- and their order is an accident of require order
---(`treesitter_fold` registers when the first chat window opens, ahead of the two that register in
---`setup()`). So "the chain happens to continue today" is not something any of them should be
---resting on, and a stale `parser/vibing.so` made the question live: the fold query threw on every
---single turn for as long as Neovim stayed up.
---
---Going through here removes the question. The callback is wrapped, so it does not throw at all; a
---failure is reported against the subscriber's own name instead of as a traceback that names
---`_finish_turn`. `tests/lua/core/events_spec.lua` fails the build on a registration that
---bypasses it.
local M = {}

local Notify = require("vibing.core.utils.notify")

---A turn finished. `data.bufnr` is the chat buffer it finished in.
M.RESPONSE_DONE = "VibingResponseDone"

---Announce that a turn finished.
---
---Measured: a throwing callback is **reported** by Neovim and the chain stops there, but nothing
---is raised back through `nvim_exec_autocmds` -- so the caller carries on and this `pcall` catches
---nothing today. It stays because the chain also carries subscribers this module does not own
---(`VibingResponseDone` is a documented extension point), and the one caller is
---`ChatBuffer:_finish_turn`, whose return is what the rest of `_handle_response` waits on. Nothing
---in that contract is promised by the API; the guard costs one closure per turn.
---@param bufnr integer The chat buffer whose turn ended
function M.emit_response_done(bufnr)
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = M.RESPONSE_DONE,
    data = { bufnr = bufnr },
  })
  if not ok then
    Notify.error(string.format("a %s handler failed: %s", M.RESPONSE_DONE, tostring(err)))
  end
end

---Subscribe to turn completion.
---
---The `bufnr` check is here rather than in each subscriber because all of them want the same
---thing: the event carries the buffer, and an event without one is not theirs to handle.
---@param group integer The augroup the subscriber owns
---@param name string The subscriber, named in the notification when its callback throws
---@param fn fun(bufnr: integer)
function M.on_response_done(group, name, fn)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = M.RESPONSE_DONE,
    callback = function(args)
      local bufnr = args.data and args.data.bufnr
      if type(bufnr) ~= "number" then
        return
      end

      local ok, err = pcall(fn, bufnr)
      if not ok then
        Notify.error(string.format("%s failed on a finished turn: %s", name, tostring(err)))
      end
    end,
  })
end

return M
