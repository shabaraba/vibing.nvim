-- E2E Tests for cross-chat completion notifications (#627)
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and this spec drives real CLI turns (the worker's, then
-- the orchestrator's woken one). Only `test:e2e` sets VIBING_E2E=1.
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  SETUP = 800,
  WORKER_TURN = 90000, -- worker's own turn plus the orchestrator turn the notification starts
  POLL = 500,
}

describe("E2E: chat completion notification", function()
  local nvim_instance

  ---@param code string
  ---@return any
  local function exec(code)
    return vim.fn.rpcrequest(nvim_instance.job_id, "nvim_exec_lua", code, {})
  end

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/e2e_init.lua",
    })
    vim.wait(TIMEOUTS.SETUP)
    exec("require('vibing').setup({ agent = { chat_notifications = { enabled = true } } })")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("wakes the sending chat with a new turn once the chat it messaged stops", function()
    local bufnrs = exec([[
      local chat = require('vibing.infrastructure.rpc.handlers.chat')
      local a = chat.create_chat({ position = 'back' })
      local b = chat.create_chat({ position = 'back', from_bufnr = a.bufnr })
      return { a.bufnr, b.bufnr }
    ]])
    local orchestrator, worker = bufnrs[1], bufnrs[2]

    assert.is_true(orchestrator > 0 and worker > 0, "both chats should be created")

    -- 作成時点で双方向のリンクが frontmatter に書かれている（#628）
    local worker_frontmatter = exec(
      string.format("return table.concat(vim.api.nvim_buf_get_lines(%d, 0, 40, false), '\\n')", worker)
    )
    assert.is_truthy(worker_frontmatter:find("orchestrated_by", 1, true), "worker should record its orchestrator")

    exec(string.format(
      [[
        require('vibing.infrastructure.rpc.handlers.message').send_message({
          bufnr = %d,
          from_bufnr = %d,
          message = 'Reply with exactly the word: done. Do not use any tools.',
        })
      ]],
      worker,
      orchestrator
    ))

    -- ワーカーが止まると、オーケストレーター側に新しい `## User` として通知が届く
    local deadline = vim.loop.now() + TIMEOUTS.WORKER_TURN
    local notified = false
    while vim.loop.now() < deadline and not notified do
      vim.wait(TIMEOUTS.POLL)
      local text = exec(
        string.format("return table.concat(vim.api.nvim_buf_get_lines(%d, 0, -1, false), '\\n')", orchestrator)
      )
      notified = text:find("finished responding", 1, true) ~= nil
    end

    assert.is_true(notified, "orchestrator should be told the worker stopped")
  end)
end)
