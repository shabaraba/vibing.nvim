-- E2E Tests: background job readiness, stop, and the passive completion policy
--
-- Companion to background_job_spec.lua, split so each file stays inside the harness's per-file
-- timeout (tests/e2e-timeout-gate.test.mjs). Assertions read the job manager's own state through
-- RPC, never the model's prose.
local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  ASSISTANT_RESPONSE = 60000,
  -- start → wait(until=ready) → stop is three MCP round-trips in one turn.
  MULTI_TOOL_TURN = 80000,
  -- SIGTERM to `sh -c '...; sleep 60'` and the exit callback.
  JOB_STOPPED = 20000,
  -- A passive Notice is appended as soon as the chat is idle.
  PASSIVE_NOTICE = 20000,
  -- Long enough for a turn to have visibly started if one were (wrongly) triggered.
  SETTLE = 5000,
  POLL = 500,
}

describe("E2E: background job readiness and passive notices", function()
  local nvim_instance

  ---@param code string
  ---@return any
  local function exec(code)
    return vim.fn.rpcrequest(nvim_instance.job_id, "nvim_exec_lua", code, {})
  end

  local function buffer_text()
    return table.concat(vim.fn.rpcrequest(nvim_instance.job_id, "nvim_buf_get_lines", 0, 0, -1, false), "\n")
  end

  local function count_assistant_headers(text)
    local count = 0
    for _ in text:gmatch("\n## [^\n]*Assistant[^\n]*") do
      count = count + 1
    end
    return count
  end

  -- `## Assistant` is written the moment the request starts; the timestamp is added when the turn
  -- ends. So "n completed turns" is n timestamped headers, not n headers — the tool calls under
  -- test happen in between. Gives up on the same `**Error:**` line the shared helper watches.
  ---@param count number
  ---@param timeout number
  ---@return boolean ok
  ---@return string? reason
  local function wait_for_completed_turns(count, timeout)
    local deadline = vim.loop.now() + timeout
    local text = ""
    while vim.loop.now() < deadline do
      text = buffer_text()
      local err = text:match("%*%*Error:%*%* [^\n]*")
      if err then
        return false, "the turn failed: " .. err
      end
      local done = 0
      for _ in text:gmatch("\n## Assistant <!%-%-") do
        done = done + 1
      end
      if done >= count then
        return true
      end
      vim.wait(TIMEOUTS.POLL)
    end
    return false, string.format("timed out waiting for %d completed turn(s)", count)
  end

  local function open_chat()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)
    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")
  end

  local function send_prompt(prompt)
    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, prompt)
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")
  end

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/e2e_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("reports readiness from the output pattern and stops on request without a Notice", function()
    open_chat()

    send_prompt(
      "Use the vibing-nvim nvim_job_start MCP tool to start the command "
        .. '["sh", "-c", "echo E2E_READY_MARK; sleep 60"] with name e2e-server, ready_pattern '
        .. "E2E_READY_MARK, notify never, and this chat's buffer number as from_bufnr. "
        .. "Then call nvim_job_wait on that job_id with until set to ready. "
        .. "Then call nvim_job_stop on the same job_id. Reply with the word: done."
    )

    local ok, reason = wait_for_completed_turns(1, TIMEOUTS.MULTI_TOOL_TURN)
    assert.is_true(ok, reason or "the start/wait/stop turn should complete")

    local jobs = exec("return require('vibing.application.job.manager').list().jobs")
    assert.equals(1, #jobs, "exactly one job should have been started")
    local job_id = jobs[1].id
    assert.equals("e2e-server", jobs[1].name)
    assert.equals("never", jobs[1].notify)

    -- Readiness came from the output substring, not from the process merely existing.
    local status
    local deadline = vim.loop.now() + TIMEOUTS.JOB_STOPPED
    repeat
      status = exec(string.format("return require('vibing.application.job.manager').status({ job_id = %q })", job_id))
      if status.status ~= "stopped" then
        vim.wait(TIMEOUTS.POLL)
      end
    until status.status == "stopped" or vim.loop.now() >= deadline

    assert.equals("ready", status.readiness, "ready_pattern should have marked the job ready: " .. vim.inspect(status))
    assert.equals("stopped", status.status, "nvim_job_stop should have terminated the job: " .. vim.inspect(status))

    -- notify = never: no Notice, and no second turn.
    local text = buffer_text()
    assert.is_nil(text:find("\n## Notice", 1, true), "notify never must not deliver a Notice")
    assert.equals(1, count_assistant_headers(text), "notify never must not start another turn")
  end)

  it("appends a passive Notice on exit without starting an LLM turn", function()
    open_chat()

    send_prompt(
      "Use the vibing-nvim nvim_job_start MCP tool to start the command "
        .. '["sh", "-c", "echo E2E_PASSIVE_OUTPUT"] with name e2e-passive, notify passive, and this '
        .. "chat's buffer number as from_bufnr. Do not wait for it and do not call any other tool. "
        .. "Reply with the word: started."
    )

    local ok, reason = wait_for_completed_turns(1, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "the turn that starts the job should complete")

    local jobs = exec("return require('vibing.application.job.manager').list().jobs")
    assert.equals(1, #jobs, "exactly one job should have been started")
    assert.equals("passive", jobs[1].notify)

    ok = helper.wait_for_buffer_content(nvim_instance, "\n## Notice", TIMEOUTS.PASSIVE_NOTICE)
    assert.is_true(ok, "a passive Notice should be appended once the job exits")

    -- Give a wrongly started turn time to write its header, then confirm none did.
    vim.wait(TIMEOUTS.SETTLE)
    local text = buffer_text()
    assert.is_truthy(text:find("Background job `e2e-passive`", 1, true), "the Notice should name the job")
    assert.is_truthy(text:find("E2E_PASSIVE_OUTPUT", 1, true), "the Notice should include the output tail")
    assert.equals(1, count_assistant_headers(text), "a passive Notice must not start another turn")

    local responding = exec(
      "local b = require('vibing.presentation.chat.view').get_chat_buffer(vim.api.nvim_get_current_buf()); "
        .. "return b and b:is_responding() or false"
    )
    assert.is_false(responding, "the chat should be idle after a passive Notice")
  end)
end)
