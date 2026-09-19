---@diagnostic disable: undefined-field
--- What happens to a hook blocked on an unanswered approval when its chat buffer goes away (#778).
---
--- This is exit 3 of the four `rpc/pending_approvals.lua` guarantees, and it has the same ordering
--- requirement as exit 4 (`tests/lua/shutdown_spec.lua`): the chat's `BufUnload` cleanup cancels the
--- CLI process, and a CLI that has been killed can no longer be the thing that stops waiting. So the
--- `.res` has to be written while the process is still alive — otherwise the orphaned hook polls to
--- its own deadline before denying with a generic message.
local Pending = require("vibing.infrastructure.rpc.pending_approvals")
local View = require("vibing.presentation.chat.view")

describe("chat view: releasing blocked approvals when the buffer goes away", function()
  local bufnr
  local order
  local callbacks
  local restore

  --- Captures the autocmds `_apply_chat_buffer_settings` registers, rather than firing a real
  --- `BufUnload`: the rest of that function touches Tree-sitter and the completion engine, and
  --- neither is what this spec is about.
  local function attach(target)
    local original_autocmd = vim.api.nvim_create_autocmd
    local original_augroup = vim.api.nvim_create_augroup
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_create_augroup = function()
      return 1
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_create_autocmd = function(events, opts)
      for _, event in ipairs(type(events) == "table" and events or { events }) do
        callbacks[event] = opts.callback
      end
      return 1
    end
    local ok, err = pcall(View._apply_chat_buffer_settings, target)
    vim.api.nvim_create_autocmd = original_autocmd
    vim.api.nvim_create_augroup = original_augroup
    assert.is_true(ok, tostring(err))
    assert.is_function(callbacks.BufUnload)
  end

  before_each(function()
    Pending._reset()
    order = {}
    callbacks = {}
    bufnr = vim.api.nvim_create_buf(false, true)

    local adapter = {
      cancel = function()
        table.insert(order, "cli")
      end,
      release_chat = function() end,
    }
    View._attached_buffers[bufnr] = {
      buf = bufnr,
      _current_process_id = "proc-1",
      _get_active_adapter = function()
        return adapter
      end,
    }

    local original_resolve_for_chat = Pending.resolve_for_chat
    ---@diagnostic disable-next-line: duplicate-set-field
    Pending.resolve_for_chat = function(chat_bufnr, reason)
      table.insert(order, "approvals:" .. tostring(chat_bufnr))
      return original_resolve_for_chat(chat_bufnr, reason)
    end

    restore = function()
      Pending.resolve_for_chat = original_resolve_for_chat
      View._attached_buffers[bufnr] = nil
    end
  end)

  after_each(function()
    restore()
    Pending._reset()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("releases this chat's blocked hooks before killing the CLI waiting inside them", function()
    attach(bufnr)
    callbacks.BufUnload()

    local approvals = vim.fn.index(order, "approvals:" .. bufnr)
    local cli = vim.fn.index(order, "cli")
    assert.is_true(approvals >= 0, "the blocked hooks were never released: " .. vim.inspect(order))
    assert.is_true(
      approvals < cli,
      "a killed CLI can no longer stop waiting, so the hook must be released first: " .. vim.inspect(order)
    )
  end)

  it("leaves another chat's blocked hook alone", function()
    -- The registry is keyed by request_id and only carries the chat alongside, so a sweep that
    -- forgot to narrow by buffer would answer prompts the user is still looking at elsewhere.
    local comm_dir = vim.fn.tempname()
    vim.fn.mkdir(comm_dir, "p")
    vim.env.VIBING_HOOK_COMM_DIR = comm_dir

    local ok, err = pcall(function()
      Pending.open({ request_id = "mine", chat_bufnr = bufnr, tool = "Bash" })
      Pending.open({ request_id = "theirs", chat_bufnr = bufnr + 1000, tool = "Bash" })

      attach(bufnr)
      callbacks.BufUnload()

      assert.is_nil(Pending.get("mine"), "this chat's pending approval should have been answered")
      assert.is_truthy(Pending.get("theirs"), "another chat's pending approval must survive")

      local f = assert(io.open(comm_dir .. "/mine.res", "r"), "no response was written for the waiting hook")
      local decoded = vim.json.decode(f:read("*a"))
      f:close()
      assert.equals("deny", decoded.hookSpecificOutput.permissionDecision)
      assert.is_truthy(decoded.hookSpecificOutput.permissionDecisionReason)
      assert.is_nil(vim.loop.fs_stat(comm_dir .. "/theirs.res"))
    end)

    vim.env.VIBING_HOOK_COMM_DIR = nil
    vim.fn.delete(comm_dir, "rf")
    assert.is_true(ok, tostring(err))
  end)

  it("still cancels the CLI when releasing the approvals throws", function()
    -- Losing the process is worse than losing the release: an unreleased hook gives up on its own
    -- deadline, where an uncancelled CLI is simply left running.
    --- Records the attempt *before* throwing, so this cannot pass by the release having been
    --- dropped altogether — asserting only that the cancel ran would be green under a mutation that
    --- deleted the whole block.
    ---@diagnostic disable-next-line: duplicate-set-field
    Pending.resolve_for_chat = function()
      table.insert(order, "approvals:throw")
      error("comm dir vanished")
    end

    attach(bufnr)
    callbacks.BufUnload()

    assert.same({ "approvals:throw", "cli" }, order)
  end)
end)
