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
end)
