local SendMessage = require("vibing.application.chat.send_message")
local AutoResume = require("vibing.application.chat.auto_resume")

describe("send_message._reschedule_rejected_message", function()
  local tmp_root
  local chat_path

  ---@param captured table filled with the text passed to set_pending_user_text (if any)
  ---@return table callbacks
  local function make_callbacks(captured)
    return {
      set_pending_user_text = function(text)
        captured.text = text
      end,
    }
  end

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    -- pending_resume resolves its store from the chat file's own directory (see
    -- pending_resume.lua's chat_scope), so anchoring the chat file inside tmp_root keeps this
    -- test's writes out of the real repository's .vibing/pending-resume.json.
    chat_path = tmp_root .. "/chat.md"
  end)

  after_each(function()
    -- schedule_request arms a real libuv timer on success; cancel it so it doesn't outlive the
    -- test (or fire against a since-deleted tmp chat file).
    pcall(AutoResume.cancel, chat_path)
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  local function make_config(enabled, max_retries)
    return { agent = { scheduled_requests = { enabled = enabled, max_retries = max_retries } } }
  end

  it("returns false when scheduled_requests is disabled", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      { resets_at = os.time() + 3600 },
      "hello",
      make_config(false, 3)
    )

    assert.is_false(ok)
    assert.is_nil(captured.text)
  end)

  it("returns false when the rate-limit info has no resets_at", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      {},
      "hello",
      make_config(true, 3)
    )

    assert.is_false(ok)
    assert.is_nil(captured.text)
  end)

  it("returns false when the message is nil", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      { resets_at = os.time() + 3600 },
      nil,
      make_config(true, 3)
    )

    assert.is_false(ok)
    assert.is_nil(captured.text)
  end)

  it("returns false when the message is blank", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      { resets_at = os.time() + 3600 },
      "   ",
      make_config(true, 3)
    )

    assert.is_false(ok)
    assert.is_nil(captured.text)
  end)

  it("returns false when chat_file_path is empty", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      "",
      { resets_at = os.time() + 3600 },
      "hello",
      make_config(true, 3)
    )

    assert.is_false(ok)
    assert.is_nil(captured.text)
  end)

  it("returns false when chat_file_path is nil", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      nil,
      { resets_at = os.time() + 3600 },
      "hello",
      make_config(true, 3)
    )

    assert.is_false(ok)
    assert.is_nil(captured.text)
  end)

  it("schedules and hands the exact rejected message to set_pending_user_text on the happy path", function()
    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      { resets_at = os.time() + 3600, limit_type = "five_hour" },
      "please continue where we left off",
      make_config(true, 3)
    )

    assert.is_true(ok)
    assert.equals("please continue where we left off", captured.text)

    local PendingResume = require("vibing.infrastructure.storage.pending_resume")
    local entry = PendingResume.get(chat_path, tmp_root)
    assert.is_not_nil(entry)
    assert.equals("scheduled", entry.kind)
  end)

  it("refuses an auto_resume continuation that was itself rejected", function()
    -- fire() sends `opts.prompt` through the ordinary send path after marking the entry
    -- in_flight, so `message` here is a string vibing.nvim wrote, not the user. Scheduling it
    -- would put that sentence in the buffer as the user's own message and hand the retry budget
    -- from auto_resume_on_limit.max_retries (1) to scheduled_requests.max_retries (3).
    local PendingResume = require("vibing.infrastructure.storage.pending_resume")
    PendingResume.put({
      chat_file_path = chat_path,
      kind = "auto_resume",
      state = "in_flight",
      retry_count = 1,
      resets_at = os.time() + 3600,
    }, tmp_root)

    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      { resets_at = os.time() + 3600, limit_type = "five_hour" },
      "Continue from where you left off.",
      make_config(true, 3)
    )

    assert.is_false(ok, "must fall through to on_rate_limited, which owns auto_resume's budget")
    assert.is_nil(captured.text, "the fixed prompt must not be written back as a user message")
    assert.equals("auto_resume", PendingResume.get(chat_path, tmp_root).kind)
  end)

  it("still re-schedules a scheduled request that was rejected again", function()
    -- The documented fire -> rejected -> re-schedule loop, which the guard above must not break.
    local PendingResume = require("vibing.infrastructure.storage.pending_resume")
    PendingResume.put({
      chat_file_path = chat_path,
      kind = "scheduled",
      state = "in_flight",
      retry_count = 1,
      resets_at = os.time() + 3600,
    }, tmp_root)

    local captured = {}
    local ok = SendMessage._reschedule_rejected_message(
      make_callbacks(captured),
      chat_path,
      { resets_at = os.time() + 3600, limit_type = "five_hour" },
      "my own message",
      make_config(true, 3)
    )

    assert.is_true(ok)
    assert.equals("my own message", captured.text)
  end)
end)
