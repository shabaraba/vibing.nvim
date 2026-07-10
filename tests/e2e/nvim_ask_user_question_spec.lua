-- E2E Tests: nvim_ask_user_question MCP tool
-- Verifies vibing.nvim's dedicated question-asking tool is intercepted the same way as
-- AskUserQuestion (deny + render an editable choice list in the chat buffer), which matters
-- because native AskUserQuestion is unavailable in headless `claude -p` mode.
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  ASSISTANT_RESPONSE = 30000,
}

--- Count how many lines in the current buffer match the given pattern.
---@param nvim_instance table
---@param pattern string Lua pattern
---@return number
local function count_lines_matching(nvim_instance, pattern)
  local lines = vim.fn.rpcrequest(nvim_instance.job_id, "nvim_buf_get_lines", { 0, 0, -1, false })
  local count = 0
  for _, line in ipairs(lines) do
    if line:match(pattern) then
      count = count + 1
    end
  end
  return count
end

describe("E2E: nvim_ask_user_question MCP tool", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("renders the same choice-list UI as AskUserQuestion, exactly once", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    -- Prompt Claude to use the vibing.nvim-dedicated question tool
    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(
      nvim_instance,
      "Use the mcp__vibing-nvim__nvim_ask_user_question tool to ask me: 'Which option?' with options A and B."
    )
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    -- Wait for question prompt (same UI as AskUserQuestion)
    ok = helper.wait_for_buffer_content(nvim_instance, "Please answer the question", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Choice-list prompt should appear")

    local count = count_lines_matching(nvim_instance, "Please answer the question")
    assert.equals(1, count, "Question prompt must appear exactly once — no duplicate UI insertion")
  end)
end)
