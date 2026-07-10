-- E2E Tests: AskUserQuestion - no repeated questions
-- Regression test for the duplicate-question bug where
-- AskUserQuestion and permissions_ask flows inserted UI multiple times.
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

describe("E2E: AskUserQuestion - no repeated questions", function()
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

  it("should display AskUserQuestion prompt exactly once", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    -- Prompt Claude to use AskUserQuestion tool
    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(
      nvim_instance,
      "Use the AskUserQuestion tool to ask me: 'Which option?' with options A and B."
    )
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    -- Wait for question prompt
    ok = helper.wait_for_buffer_content(nvim_instance, "Please answer the question", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "AskUserQuestion prompt should appear")

    -- Verify prompt appears exactly once (regression: was duplicated before the fix)
    local count = count_lines_matching(nvim_instance, "Please answer the question")
    assert.equals(1, count, "Question prompt must appear exactly once — no duplicate UI insertion")
  end)

  it("should not repeat the question prompt after user answers", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    -- Prompt Claude to use AskUserQuestion tool
    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(
      nvim_instance,
      "Use the AskUserQuestion tool to ask me: 'Which color?' with options Red and Blue."
    )
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    -- Wait for question prompt to appear
    ok = helper.wait_for_buffer_content(nvim_instance, "Please answer the question", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "AskUserQuestion prompt should appear")

    -- Send an answer by pressing <CR> (all options remain — Claude understands)
    helper.send_keys(nvim_instance, "<CR>")

    -- Wait for Claude to process the answer and produce a follow-up response
    ok = helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Claude should respond after the answer is sent")

    -- Verify prompt still appears only once (not re-inserted after answering)
    local count = count_lines_matching(nvim_instance, "Please answer the question")
    assert.equals(1, count, "Question prompt must not be re-inserted after the user answers")
  end)
end)
