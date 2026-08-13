-- E2E Tests for scheduled requests (usage-limit request parking)
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and the fired request below is a real CLI call.
-- Only `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  BUFFER_READY = 8000, -- Chat buffer created and rendered
  COMMAND = 3000, -- A user command / <CR> has been processed
  -- compute_delay clamps anything under 3s up to 3s, and the fired request is a real CLI call.
  SCHEDULED_SEND = 90000,
}

-- Resolved from this spec's own path rather than the cwd: the spawned instances run in a
-- throwaway repo, and `init_script` has to be absolute for them to find the plugin at all.
local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local INIT_SCRIPT = PLUGIN_ROOT .. "/tests/minimal_init.lua"

---@param instance table
---@param code string
---@return any
local function exec_lua(instance, code)
  return vim.fn.rpcrequest(instance.job_id, "nvim_exec_lua", code, {})
end

---@param tmp string
---@return table<string, table>
local function read_pending(tmp)
  local path = tmp .. "/.vibing/pending-resume.json"
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return (ok and type(decoded) == "table") and decoded or {}
end

---Cancellation empties the store rather than deleting the file, so "no entry" means "no key".
---@param tmp string
---@return table|nil entry, string|nil chat_path
local function first_pending(tmp)
  for path, entry in pairs(read_pending(tmp)) do
    return entry, path
  end
  return nil, nil
end

---The store is only cleared once the whole response completes, which is later than the first
---streamed text, so "delivered" has to be waited for rather than sampled.
---@param tmp string
---@param timeout_ms number
---@return boolean cleared
local function wait_for_no_pending(tmp, timeout_ms)
  local deadline = vim.loop.hrtime() + timeout_ms * 1000000
  repeat
    if first_pending(tmp) == nil then
      return true
    end
    vim.loop.sleep(200)
  until vim.loop.hrtime() > deadline
  return false
end

---@param tmp string
---@param timeout_ms number
---@return table|nil entry, string|nil chat_path
local function wait_for_pending(tmp, timeout_ms)
  local deadline = vim.loop.hrtime() + timeout_ms * 1000000
  repeat
    local entry, path = first_pending(tmp)
    if entry then
      return entry, path
    end
    vim.loop.sleep(100)
  until vim.loop.hrtime() > deadline
  return nil, nil
end

---A chat file has to exist on disk before it can be scheduled, so wait for the buffer to be one.
---@param instance table
---@return string chat_file_path
local function open_chat(instance)
  helper.send_keys(instance, ":VibingChat<CR>")
  assert.is_true(
    helper.wait_for_buffer_content(instance, "## User <!%-%- unsent %-%->", TIMEOUTS.BUFFER_READY),
    "Chat buffer should be created with an unsent User section"
  )
  local chat_file_path = exec_lua(instance, "return vim.api.nvim_buf_get_name(0)")
  assert.is_truthy(chat_file_path:match("%.md$"), "Chat buffer should be backed by a .md file, got: " .. chat_file_path)
  return chat_file_path
end

---@param instance table
---@param text string
local function type_message(instance, text)
  helper.send_keys(instance, "G")
  vim.wait(150)
  helper.send_keys(instance, "i")
  helper.send_keys(instance, text)
  helper.send_keys(instance, "<Esc>")
  vim.wait(300)
end

describe("E2E: Scheduled requests", function()
  local nvim_instance
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    -- A real repo so limit_state/pending_resume resolve the same root the plugin will.
    vim.fn.system({ "git", "-C", tmp, "init", "-q" })

    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = INIT_SCRIPT,
      cwd = tmp,
    })
    vim.wait(800)
    -- minimal_init only puts the plugin on the runtimepath; the user commands under test are
    -- registered by setup(), so the child has to be set up explicitly.
    exec_lua(nvim_instance, "require('vibing').setup({})")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
    if tmp then
      vim.fn.delete(tmp, "rf")
    end
  end)

  it("parks a message instead of sending it while a limit is on record", function()
    -- Pretend the plan's limit was observed a moment ago and lifts in an hour.
    vim.fn.mkdir(tmp .. "/.vibing", "p")
    vim.fn.writefile({
      vim.json.encode({ resets_at = os.time() + 3600, limit_type = "five_hour", observed_at = os.time() }),
    }, tmp .. "/.vibing/limit-state.json")

    local chat_file_path = open_chat(nvim_instance)
    type_message(nvim_instance, "please do the thing")
    helper.send_keys(nvim_instance, "<CR>")

    local entry, path = wait_for_pending(tmp, TIMEOUTS.COMMAND)
    assert.is_not_nil(entry, "A pending entry should have been written")
    assert.equals("scheduled", entry.kind)
    assert.equals("waiting", entry.state)
    assert.equals(chat_file_path, path)

    -- The header keeps its unsent marker: commit_user_message was never reached. The marker is
    -- anchored to the body so that "park it, but stamp the header anyway and append a fresh
    -- unsent section below" would fail here rather than pass on the appended header.
    local content = exec_lua(nvim_instance, "return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
    assert.is_truthy(
      content:match("## User <!%-%- unsent %-%->\nplease do the thing"),
      "The parked message should still sit under an unsent User header, got:\n" .. content
    )
    assert.is_nil(content:match("## Assistant"), "Nothing should have been sent")
  end)

  it("cancels a scheduled request without losing the message", function()
    open_chat(nvim_instance)
    type_message(nvim_instance, "not yet please")

    helper.send_keys(nvim_instance, ":VibingSchedule 1h<CR>")
    assert.is_not_nil(wait_for_pending(tmp, TIMEOUTS.COMMAND), "The request should be armed")

    helper.send_keys(nvim_instance, ":VibingCancelResume<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    assert.is_nil(first_pending(tmp), "The entry should be gone")
    local content = exec_lua(nvim_instance, "return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
    -- Anchored for the same reason as the parking scenario: the message has to still be the
    -- unsent one, not a stamped send with an empty unsent section appended after it.
    assert.is_truthy(
      content:match("## User <!%-%- unsent %-%->\nnot yet please"),
      "Cancelling must leave the message unsent and ready to send, got:\n" .. content
    )
  end)

  it("sends the parked message when the scheduled time arrives", function()
    open_chat(nvim_instance)
    type_message(nvim_instance, 'Say "scheduled"')

    helper.send_keys(nvim_instance, ":VibingSchedule 1s<CR>")
    local entry = wait_for_pending(tmp, TIMEOUTS.COMMAND)
    assert.is_not_nil(entry, "The request should be armed")
    assert.equals("scheduled", entry.kind)

    -- Proof of delivery, not merely of dispatch: the answer has to come back under the Assistant
    -- header. `[^#]*` keeps the match inside that one section, and the prompt is trivial enough
    -- that the reply is the word itself.
    assert.is_true(
      helper.wait_for_buffer_content(nvim_instance, "## Assistant\n[^#]*[Ss]cheduled", TIMEOUTS.SCHEDULED_SEND),
      "The scheduled request should have been sent and answered"
    )

    -- Sending stamps the header with a timestamp and drops the unsent marker.
    local content = exec_lua(nvim_instance, "return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')")
    assert.is_truthy(
      content:match('## User <!%-%- %d%d%d%d%-%d%d%-%d%d [%d:]+ %-%->\nSay "scheduled"'),
      "The sent message's header should carry a send timestamp instead of the unsent marker"
    )
    assert.is_true(
      wait_for_no_pending(tmp, TIMEOUTS.SCHEDULED_SEND),
      "A delivered request should no longer be pending once the response completes"
    )
  end)
end)
