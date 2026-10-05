-- E2E Tests: a multiple-choice question asked as a block at the end of the reply
-- The model is told (system prompt) to end its turn with a ```vibing-question block; vibing.nvim
-- turns that block into an editable choice list in the next unsent section
-- (`presentation/chat/modules/question_block.lua`). Native AskUserQuestion is unavailable in
-- headless `claude -p` mode, and the old `nvim_ask_user_question` MCP tool is gone.
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
  -- Kept at the tool-era budget until a run of the block protocol is measured: no ToolSearch or
  -- MCP round trip any more, so this should only be generous.
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

local function define_backend_case(backend, timeouts)
  describe("E2E: question block (" .. backend.name .. ")", function()
    local nvim_instance

    before_each(function()
      nvim_instance = helper.spawn_nvim_instance({
        headless = true,
        init_script = "tests/e2e_init.lua",
        adapter = backend.name,
      })
    end)

    after_each(function()
      helper.cleanup_instance(nvim_instance)
    end)

    it("renders the choice list exactly once and drops the raw block", function()
      helper.send_keys(nvim_instance, ":VibingChat<CR>")
      vim.wait(timeouts.CHAT_CREATION)

      local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", timeouts.BUFFER_READY)
      assert.is_true(ok, "Chat buffer should be created")

      helper.send_keys(nvim_instance, "G")
      helper.send_keys(nvim_instance, "i")
      helper.send_keys(
        nvim_instance,
        "Ask me to choose, the way your system prompt says to: 'Which option?' with options A and B."
      )
      helper.send_keys(nvim_instance, "<Esc>")
      helper.send_keys(nvim_instance, "<CR>")

      local reason
      ok, reason = helper.wait_for_response(nvim_instance, "\n1%. A\n", timeouts.ASSISTANT_RESPONSE)
      assert.is_true(ok, reason or "Choice-list prompt should appear")

      local count = count_lines_matching(nvim_instance, "^1%. A$")
      assert.equals(1, count, "The question must be rendered exactly once — no duplicate UI insertion")
      assert.equals(
        0,
        count_lines_matching(nvim_instance, "^%s*```vibing%-question"),
        "The JSON block must be taken out of the transcript once it is drawn as choices"
      )
    end)
  end)
end

-- Keep each backend's TIMEOUTS references explicit. The timeout gate counts those references to
-- model the file's serial worst case, while define_backend_case keeps the test behaviour shared.
define_backend_case(
  { name = "claude" },
  {
    CHAT_CREATION = TIMEOUTS.CHAT_CREATION,
    BUFFER_READY = TIMEOUTS.BUFFER_READY,
    ASSISTANT_RESPONSE = TIMEOUTS.ASSISTANT_RESPONSE,
  }
)
define_backend_case(
  { name = "codex" },
  {
    CHAT_CREATION = TIMEOUTS.CHAT_CREATION,
    BUFFER_READY = TIMEOUTS.BUFFER_READY,
    ASSISTANT_RESPONSE = TIMEOUTS.ASSISTANT_RESPONSE,
  }
)
