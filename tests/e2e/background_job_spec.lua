-- E2E Tests: Neovim-owned background jobs (nvim_job_start and the Bash backgrounding gate)
--
-- Two halves of one feature: the model is told (system prompt) and forced (PreToolUse hook) to
-- start long-running processes through `nvim_job_start`, and the process that results is owned by
-- Neovim, so its exit reaches the chat as a `## Notice` after the CLI turn that started it is gone.
--
-- Assertions read what vibing.nvim itself records — the job manager's table and the hook's
-- permission decision — never the model's prose, so a rewording cannot make this flaky.
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and every spec here drives a real CLI turn.
-- Only `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  -- The turn has to discover the tool through ToolSearch and round-trip the MCP server, like
  -- nvim_ask_user_question_spec; same budget.
  ASSISTANT_RESPONSE = 60000,
  -- After the job exits, the queued Notice starts a fresh turn on an idle chat. This covers the
  -- process exit, the queue flush and that second turn.
  NOTICE_WAKE = 50000,
  POLL = 500,
  -- One hook round trip: nc, the RPC handler, the response file. The script itself polls for
  -- up to 120s, so this is the spec's bound, not the protocol's.
  HOOK_ROUND_TRIP = 15000,
}

describe("E2E: Neovim-owned background jobs", function()
  local nvim_instance

  ---@param code string
  ---@return any
  local function exec(code)
    return vim.fn.rpcrequest(nvim_instance.job_id, "nvim_exec_lua", code, {})
  end

  local function buffer_text()
    return table.concat(vim.fn.rpcrequest(nvim_instance.job_id, "nvim_buf_get_lines", 0, 0, -1, false), "\n")
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

  it("delivers the job's exit as a Notice that wakes the chat with a new turn", function()
    open_chat()

    send_prompt(
      "Use the vibing-nvim nvim_job_start MCP tool to start the command "
        .. '["sh", "-c", "echo E2E_JOB_OUTPUT"] with name e2e-echo, passing this chat\'s buffer '
        .. "number as from_bufnr. Do not wait for it and do not call any other tool. Reply with the word: started."
    )

    local ok, reason = wait_for_completed_turns(1, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "the turn that starts the job should complete")

    -- The tool call is what is under test, and the manager's table is where it lands.
    local jobs = exec("return require('vibing.application.job.manager').list().jobs")
    assert.equals(1, #jobs, "nvim_job_start should have registered exactly one job")
    assert.equals("e2e-echo", jobs[1].name, "the job should carry the requested name")
    assert.equals("always", jobs[1].notify, "notify should default to always")

    -- The process is Neovim's, so its exit reaches the chat after the CLI turn is gone: a
    -- `## Notice` section, and — because notify is `always` — a second assistant turn on it.
    ok, reason = wait_for_completed_turns(2, TIMEOUTS.NOTICE_WAKE)
    assert.is_true(ok, reason or "the completion Notice should start a second turn")

    local text = buffer_text()
    assert.is_truthy(text:find("\n## Notice", 1, true), "a Notice section should have been delivered")
    assert.is_truthy(text:find("Background job `e2e-echo`", 1, true), "the Notice should name the job")
    assert.is_truthy(text:find("exited with code 0", 1, true), "the Notice should carry the exit status")
    assert.is_truthy(text:find("E2E_JOB_OUTPUT", 1, true), "the Notice should include the output tail")

    local status = exec(string.format("return require('vibing.application.job.manager').status({ job_id = %q })", jobs[1].id))
    assert.equals("exited", status.status)
    assert.equals(0, status.exit_code)
    assert.equals(1, vim.fn.filereadable(status.log_path), "the full log should be written under .vibing/jobs/")
  end)

  it("denies Bash backgrounding through the PreToolUse hook and points at nvim_job_start", function()
    -- Driven without the model, deliberately. The system prompt forbids exactly the call this
    -- spec needs, and whether the model attempts it anyway is a coin toss (observed both ways),
    -- so an LLM-driven version asserts nothing on a bad day. What has to hold is the chain the
    -- model would hit when it does try: the hook script → nc → the child's RPC server → the
    -- policy in can_use_tool → the response file → exit 2 with the redirect on stderr. Running
    -- the real script against the real child covers all of it; tests/e2e_init.lua's Bash deny is
    -- irrelevant because that list is enforced by the CLI (`--disallowedTools`), not here.
    open_chat()

    local port = exec("return require('vibing.infrastructure.rpc.server').get_port()")
    assert.is_true(type(port) == "number" and port > 0, "the child's RPC server should be listening")

    -- Record the decision where it is made, which also proves the request reached *this* child.
    exec([[
      local cut = require('vibing.infrastructure.permissions.can_use_tool')
      _G.__e2e_decisions = {}
      local original = cut.can_use_tool
      cut.can_use_tool = function(tool_name, input, config)
        local result = original(tool_name, input, config)
        table.insert(_G.__e2e_decisions, {
          tool = tool_name,
          command = type(input) == 'table' and input.command or nil,
          behavior = result.behavior,
          message = result.message,
        })
        return result
      end
    ]])

    ---@param tool_input table
    ---@return vim.SystemCompleted
    local function run_hook(tool_input)
      local payload = vim.json.encode({
        hook_event_name = "PreToolUse",
        tool_name = "Bash",
        tool_input = tool_input,
      })
      return vim.system({ vim.fn.getcwd() .. "/bin/hooks/pre-tool-use.sh" }, {
        stdin = payload,
        env = { VIBING_NVIM_RPC_PORT = tostring(port) },
        text = true,
      }):wait(TIMEOUTS.HOOK_ROUND_TRIP)
    end

    local ampersand = run_hook({ command = "sleep 2 &" })
    assert.equals(2, ampersand.code, "a trailing & must be denied (exit 2): " .. vim.inspect(ampersand))
    assert.is_truthy(
      (ampersand.stderr or ""):find("nvim_job_start", 1, true),
      "the refusal must point at nvim_job_start: " .. tostring(ampersand.stderr)
    )

    local native = run_hook({ command = "npm run dev", run_in_background = true })
    assert.equals(2, native.code, "Bash's own run_in_background must be denied: " .. vim.inspect(native))

    -- The gate is specific: a foreground command passes, and passes as "defer" (silent exit 0),
    -- never as an explicit grant that would skip the CLI's own settings.json rules.
    local foreground = run_hook({ command = "echo hi" })
    assert.equals(0, foreground.code, "a foreground command must not be denied: " .. vim.inspect(foreground))
    assert.equals("", foreground.stdout or "", "a permitted Bash call is a defer, not an allow")

    local decisions = exec("return _G.__e2e_decisions")
    local denied, allowed = 0, 0
    for _, decision in ipairs(decisions) do
      if decision.tool == "Bash" and decision.behavior == "deny" then
        denied = denied + 1
        assert.is_truthy(decision.message and decision.message:find("nvim_job_start", 1, true))
      elseif decision.tool == "Bash" and decision.behavior == "allow" then
        allowed = allowed + 1
      end
    end
    assert.equals(2, denied, "both detached forms should have been denied by this child: " .. vim.inspect(decisions))
    assert.equals(1, allowed, "the foreground command should have been evaluated by this child: " .. vim.inspect(decisions))
  end)
end)
