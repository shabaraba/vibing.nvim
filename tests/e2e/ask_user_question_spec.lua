-- E2E Tests: AskUserQuestion - no repeated questions
-- Regression test for the duplicate-question bug where
-- AskUserQuestion and permissions_ask flows inserted UI multiple times.
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and some of these specs send a real request to the CLI.
-- Only `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

-- These two specs depend on the model echoing the option labels it was told to use, so the
-- assertions below match the rendered `1. A` / `1. Red` lines verbatim. That is a deliberate
-- departure from the eval harness's rule of never reading response prose (see
-- .claude/rules/self-testing.md): here the rendered list *is* the thing under test, and the
-- renderer copies `opt.label` straight through. If the model ever paraphrases a label, this goes
-- flaky — the fix is to loosen the pattern, not to conclude the UI broke.
local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  -- Longer than chat_basic_flow's 30s: those turns answer directly, while these have to find
  -- the tool through ToolSearch and round-trip through the MCP server first. Measured, not guessed.
  ASSISTANT_RESPONSE = 60000,
}

--- Count how many lines in the current buffer match the given pattern.
---@param nvim_instance table
---@param pattern string Lua pattern
---@return number
local function count_lines_matching(nvim_instance, pattern)
  local lines = vim.fn.rpcrequest(nvim_instance.job_id, "nvim_buf_get_lines", 0, 0, -1, false)
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
      init_script = "tests/e2e_init.lua",
    })
    vim.wait(800)
    -- minimal_init only puts the plugin on the runtimepath; the :Vibing* commands these specs
    -- drive are registered by setup(), so the child has to be set up explicitly.
    vim.fn.rpcrequest(nvim_instance.job_id, "nvim_exec_lua", "require('vibing').setup({})", {})
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("should display AskUserQuestion prompt exactly once", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
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
    ok = helper.wait_for_buffer_content(nvim_instance, "\n1%. A\n", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Choice list should be rendered into the buffer")

    -- Verify prompt appears exactly once (regression: was duplicated before the fix)
    local count = count_lines_matching(nvim_instance, "^1%. A$")
    assert.equals(1, count, "The question must be rendered exactly once — no duplicate UI insertion")
  end)

  it("should not repeat the question prompt after user answers", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
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
    ok = helper.wait_for_buffer_content(nvim_instance, "\n1%. Red\n", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Choice list should be rendered into the buffer")

    -- Send an answer by pressing <CR> (all options remain — Claude understands)
    helper.send_keys(nvim_instance, "<CR>")

    -- Wait for Claude to process the answer and produce a follow-up response
    ok = helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Claude should respond after the answer is sent")

    -- Verify prompt still appears only once (not re-inserted after answering)
    local count = count_lines_matching(nvim_instance, "^1%. Red$")
    assert.equals(1, count, "Question prompt must not be re-inserted after the user answers")
  end)
end)
