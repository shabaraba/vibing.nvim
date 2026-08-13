-- Tests for ChatBuffer:_try_schedule_instead_of_send (park a message instead of sending it
-- while a usage limit is known to be active). Exercises the helper directly against a real,
-- named scratch buffer rather than going through the full send_message()/CLI lifecycle.

describe("ChatBuffer:_try_schedule_instead_of_send", function()
  local ChatBuffer = require("vibing.presentation.chat.buffer")
  local Config = require("vibing.config")
  local LimitState = require("vibing.infrastructure.storage.limit_state")
  local AutoResume = require("vibing.application.chat.auto_resume")
  local PendingResume = require("vibing.infrastructure.storage.pending_resume")

  local tmp_root
  local original_config_get
  local created_bufs
  local created_chat_paths

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    original_config_get = Config.get
    created_bufs = {}
    created_chat_paths = {}
  end)

  after_each(function()
    Config.get = original_config_get
    LimitState.clear(tmp_root)
    -- Cancel unconditionally (not just on the happy path's own assertions) so a failed
    -- assertion mid-test can never leave a live libuv timer or a store entry behind.
    for _, chat_path in ipairs(created_chat_paths) do
      AutoResume.cancel(chat_path)
    end
    for _, bufnr in ipairs(created_bufs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  --- @param scheduled_opts table|nil
  --- @param auto_resume_opts table|nil
  local function stub_config(scheduled_opts, auto_resume_opts)
    Config.get = function()
      return {
        agent = {
          scheduled_requests = scheduled_opts or { enabled = true, max_retries = 3 },
          auto_resume_on_limit = auto_resume_opts or { grace_sec = 10 },
        },
      }
    end
  end

  --- Build a minimal ChatBuffer instance around a real, named buffer carrying an unsent
  --- `## User` section, without going through :new()/open() (which need window_manager,
  --- file_manager, etc.). The helper under test only touches self.buf and self._pending_approval.
  --- @param message string
  --- @return table chat_buffer, string chat_path
  local function make_buffer(message)
    local bufnr = vim.api.nvim_create_buf(false, false)
    table.insert(created_bufs, bufnr)
    vim.api.nvim_buf_set_name(bufnr, tmp_root .. "/chat.md")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "## User <!-- unsent -->",
      message,
    })
    -- nvim_buf_set_name resolves symlinks in an already-existing directory (e.g. macOS
    -- /tmp -> /private/tmp), so the name actually stored can differ from what was passed in.
    -- Read it back rather than assuming it round-trips, since the helper under test and the
    -- store lookups below must agree on the exact path.
    local chat_path = vim.api.nvim_buf_get_name(bufnr)
    table.insert(created_chat_paths, chat_path)
    local instance = setmetatable({ buf = bufnr, _pending_approval = nil }, ChatBuffer)
    return instance, chat_path
  end

  --- Build a ChatBuffer whose `:write` deterministically fails, WITHOUT changing its directory
  --- from tmp_root. This matters: the helper looks up the active limit via
  --- `LimitState.get_active(fnamemodify(chat_file_path, ":h"))`, and every test in this file
  --- records the limit under `tmp_root`. An earlier version of this fixture pointed the buffer at
  --- `tmp_root .. "/no-such-subdir/chat.md"` to force a write failure, which silently broke that
  --- lookup (dirname became `tmp_root/no-such-subdir`, a different, empty store) — the helper then
  --- returned false at the earlier "no active limit" guard, never reaching the save/arm code the
  --- test claimed to cover. Pre-creating the target path itself as a directory reproduces a real
  --- `:write` failure (can't write a file where a directory already exists) while keeping the
  --- buffer's dirname exactly `tmp_root`, so the lookup still lines up.
  --- @param message string
  --- @return table chat_buffer, string chat_path
  local function make_unwritable_buffer(message)
    local chat_path = tmp_root .. "/chat.md"
    vim.fn.mkdir(chat_path, "p")

    local bufnr = vim.api.nvim_create_buf(false, false)
    table.insert(created_bufs, bufnr)
    vim.api.nvim_buf_set_name(bufnr, chat_path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "## User <!-- unsent -->",
      message,
    })
    chat_path = vim.api.nvim_buf_get_name(bufnr)
    table.insert(created_chat_paths, chat_path)
    local instance = setmetatable({ buf = bufnr, _pending_approval = nil }, ChatBuffer)
    return instance, chat_path
  end

  describe("exclusions", function()
    before_each(function()
      stub_config()
    end)

    it("does not park a slash command, even with an active limit", function()
      local chat_buf, chat_path = make_buffer("/help")
      LimitState.record({ resets_at = os.time() + 3600, limit_type = "five_hour" }, tmp_root)

      local scheduled = chat_buf:_try_schedule_instead_of_send("/help")

      assert.is_false(scheduled)
      assert.is_nil(PendingResume.get(chat_path))
    end)

    it("does not park an approval response, even with an active limit", function()
      local response = "1. allow_once - Allow this execution only"
      local chat_buf, chat_path = make_buffer(response)
      chat_buf._pending_approval = { tool = "Bash" }
      LimitState.record({ resets_at = os.time() + 3600, limit_type = "five_hour" }, tmp_root)

      local scheduled = chat_buf:_try_schedule_instead_of_send(response)

      assert.is_false(scheduled)
      assert.is_nil(PendingResume.get(chat_path))
    end)
  end)

  it("does nothing when scheduled_requests.enabled is false", function()
    stub_config({ enabled = false, max_retries = 3 })
    local chat_buf, chat_path = make_buffer("hello")
    LimitState.record({ resets_at = os.time() + 3600, limit_type = "five_hour" }, tmp_root)

    local scheduled = chat_buf:_try_schedule_instead_of_send("hello")

    assert.is_false(scheduled)
    assert.is_nil(PendingResume.get(chat_path))
  end)

  it("does nothing when there is no active limit record", function()
    stub_config()
    local chat_buf, chat_path = make_buffer("hello")

    local scheduled = chat_buf:_try_schedule_instead_of_send("hello")

    assert.is_false(scheduled)
    assert.is_nil(PendingResume.get(chat_path))
  end)

  it("parks the message and leaves the unsent header intact when a limit is active", function()
    stub_config()
    local chat_buf, chat_path = make_buffer("hello there")
    local resets_at = os.time() + 3600
    LimitState.record({ resets_at = resets_at, limit_type = "five_hour" }, tmp_root)

    local scheduled = chat_buf:_try_schedule_instead_of_send("hello there")

    assert.is_true(scheduled)

    local entry = PendingResume.get(chat_path)
    assert.is_not_nil(entry)
    assert.equals("scheduled", entry.kind)
    assert.equals("waiting", entry.state)
    assert.equals("five_hour", entry.limit_type)

    local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, 1, false)
    assert.matches("unsent", lines[1])
  end)

  it("does not arm a schedule when the chat file cannot be saved (fails open)", function()
    stub_config()
    local chat_buf, chat_path = make_unwritable_buffer("hello there")
    LimitState.record({ resets_at = os.time() + 3600, limit_type = "five_hour" }, tmp_root)

    -- Sanity check on the fixture itself: this must be truthy, or the assertions below would
    -- pass for the wrong reason (the earlier "no active limit" guard) instead of proving the
    -- save-failure guard was reached. This is exactly the mismatch that made the previous version
    -- of this test vacuous.
    assert.is_not_nil(LimitState.get_active(vim.fn.fnamemodify(chat_path, ":h")))

    -- Track whether AutoResume.schedule_request is invoked at all, without fully replacing the
    -- module (other tests in this file rely on the real one). If the save-failure guard were
    -- ever skipped or moved after the arm call, this would flip true.
    local schedule_request_called = false
    local original_schedule_request = AutoResume.schedule_request
    AutoResume.schedule_request = function(...)
      schedule_request_called = true
      return original_schedule_request(...)
    end

    -- The save-failure branch is the only silent-guard exit that also calls vim.notify (the
    -- earlier guards - disabled config, slash command, approval response, no active limit - all
    -- return false without notifying anything). Capturing the message is therefore a second,
    -- independent signal that this specific guard fired, not an earlier one.
    local notified = {}
    local original_notify = vim.notify
    vim.notify = function(msg)
      table.insert(notified, msg)
    end

    local scheduled = chat_buf:_try_schedule_instead_of_send("hello there")

    vim.notify = original_notify
    AutoResume.schedule_request = original_schedule_request

    assert.is_false(scheduled)
    assert.is_false(
      schedule_request_called,
      "AutoResume.schedule_request must not be called when the save failed"
    )
    assert.is_nil(PendingResume.get(chat_path))
    -- The failed `:write` left the buffer's unsaved-changes flag set; a passing save would have
    -- cleared it. This is the same signal the helper itself checks before arming.
    assert.is_true(vim.bo[chat_buf.buf].modified)

    local found_save_warning = false
    for _, msg in ipairs(notified) do
      if msg:match("[Cc]ould not save") then
        found_save_warning = true
        break
      end
    end
    assert.is_true(
      found_save_warning,
      "expected a 'could not save' warning naming the reason; got: " .. vim.inspect(notified)
    )
  end)

  describe("send_message() ordering", function()
    -- The test above calls the helper directly, which never touches buffer text and so cannot
    -- distinguish "helper runs before commit_user_message" from "helper runs after" — it would
    -- pass either way. This test instead drives the real ChatBuffer:send_message() (with real,
    -- unstubbed collaborators: commands, approval_parser, conversation_extractor), which is the
    -- only place the ordering promise in the brief actually lives. Moving the scheduling branch
    -- in send_message() to after ConversationExtractor.commit_user_message(self.buf) must make
    -- this test fail — verified manually (see task-7-report.md, "Fix round 1").
    before_each(function()
      stub_config()
    end)

    it("never reaches commit_user_message: the header stays unsent when send_message() parks it", function()
      local chat_buf, chat_path = make_buffer("hello there")
      LimitState.record({ resets_at = os.time() + 3600, limit_type = "five_hour" }, tmp_root)

      chat_buf:send_message()

      assert.is_false(chat_buf._is_sending)

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, 1, false)
      assert.matches("unsent", lines[1], "commit_user_message must not have run before the schedule check")

      local entry = PendingResume.get(chat_path)
      assert.is_not_nil(entry)
      assert.equals("scheduled", entry.kind)
    end)
  end)
end)
