describe("auto_resume", function()
  local PendingResume = require("vibing.infrastructure.storage.pending_resume")

  local tmp_root

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
  end)

  after_each(function()
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  describe("restore eligibility", function()
    -- restore() arms libuv timers, so rather than wait on wall-clock these tests assert the
    -- predicate restore() filters on: only "waiting" entries are eligible to be re-armed.
    ---@param entry table
    ---@return boolean
    local function is_restorable(entry)
      return entry.chat_file_path ~= nil and (entry.state or "waiting") == "waiting"
    end

    it("re-arms a chat still waiting on its reset", function()
      PendingResume.put({
        chat_file_path = "/a.md",
        resets_at = 1778193600,
        retry_count = 0,
        recorded_at = 1,
        state = "waiting",
      }, tmp_root)

      assert.is_true(is_restorable(PendingResume.get("/a.md", tmp_root)))
    end)

    it("does not re-send a resume that was already in flight when Neovim died (regression)", function()
      -- fire() marks the entry in_flight before sending. Without this guard a restart would
      -- schedule it again and spend a second request outside the retry budget.
      PendingResume.put({
        chat_file_path = "/b.md",
        resets_at = 1778193600,
        retry_count = 1,
        recorded_at = 1,
        state = "in_flight",
      }, tmp_root)

      local entry = PendingResume.get("/b.md", tmp_root)
      assert.is_false(is_restorable(entry))
      -- The entry survives so its retry_count still counts against max_retries.
      assert.equals(1, entry.retry_count)
    end)

    it("treats a missing state as waiting", function()
      PendingResume.put({ chat_file_path = "/c.md", retry_count = 0, recorded_at = 1 }, tmp_root)

      assert.is_true(is_restorable(PendingResume.get("/c.md", tmp_root)))
    end)
  end)

  describe("compute_delay", function()
    local AutoResume = require("vibing.application.chat.auto_resume")
    local OPTS = { fallback_delay_sec = 300, grace_sec = 10 }

    it("waits until the reset plus the grace period", function()
      local resets_at = os.time() + 3600
      local delay = AutoResume._compute_delay({ resets_at = resets_at }, OPTS)

      -- Timing-tolerant: os.time() may tick between the fixture and the call.
      assert.is_true(delay >= 3605 and delay <= 3610)
    end)

    it("falls back to fallback_delay_sec when no reset time was reported", function()
      assert.equals(300, AutoResume._compute_delay({}, OPTS))
    end)

    it("clamps an already-elapsed reset to a short delay rather than firing instantly", function()
      -- Neovim was closed across the whole window; let startup settle before a request goes out.
      local delay = AutoResume._compute_delay({ resets_at = os.time() - 10000 }, OPTS)

      assert.equals(3, delay)
    end)

    it("refuses an implausible reset more than 8 days out", function()
      local delay, reason = AutoResume._compute_delay({ resets_at = os.time() + 30 * 86400 }, OPTS)

      -- A misread payload (wrong unit or field) must not arm a timer for weeks.
      assert.is_nil(delay)
      assert.truthy(reason:match("days away"))
    end)

    it("accepts a reset just inside the 8-day ceiling", function()
      local delay = AutoResume._compute_delay({ resets_at = os.time() + 7 * 86400 }, OPTS)

      assert.is_not_nil(delay)
    end)
  end)

  describe("on_rate_limited", function()
    local AutoResume = require("vibing.application.chat.auto_resume")
    local Config = require("vibing.config")
    local original_get
    local chat_path

    ---@param auto_resume_opts table
    local function stub_config(auto_resume_opts)
      Config.get = function()
        return { agent = { auto_resume_on_limit = auto_resume_opts } }
      end
    end

    before_each(function()
      original_get = Config.get
      -- Per-chat store operations resolve from the chat file's own directory, so a chat path
      -- inside tmp_root keeps this test off the real repository.
      chat_path = tmp_root .. "/chat.md"
    end)

    after_each(function()
      Config.get = original_get
    end)

    it("does not park a chat while the feature is disabled", function()
      stub_config({ enabled = false })

      AutoResume.on_rate_limited(chat_path, { rejected = true, resets_at = os.time() + 60, source = "test" })

      assert.is_nil(PendingResume.get(chat_path))
    end)

    it("parks a chat in the waiting state on the first limit hit", function()
      stub_config({ enabled = true, max_retries = 1 })
      local resets_at = os.time() + 3600

      AutoResume.on_rate_limited(chat_path, {
        rejected = true,
        resets_at = resets_at,
        limit_type = "five_hour",
        source = "test",
      })

      local entry = PendingResume.get(chat_path)
      assert.is_not_nil(entry)
      assert.equals("waiting", entry.state)
      assert.equals(0, entry.retry_count)
      assert.equals(resets_at, entry.resets_at)

      AutoResume.cancel(chat_path)
    end)

    it("gives up instead of re-parking once the retry budget is spent", function()
      stub_config({ enabled = true, max_retries = 1 })
      PendingResume.put({
        chat_file_path = chat_path,
        resets_at = os.time() + 60,
        retry_count = 1,
        recorded_at = os.time(),
        state = "in_flight",
      })

      AutoResume.on_rate_limited(chat_path, { rejected = true, resets_at = os.time() + 3600, source = "test" })

      -- The entry is dropped, not refreshed: a second auto-resume would exceed max_retries.
      assert.is_nil(PendingResume.get(chat_path))
    end)

    it("ignores a chat with no file path", function()
      stub_config({ enabled = true, max_retries = 1 })

      assert.has_no.errors(function()
        AutoResume.on_rate_limited(nil, { rejected = true, source = "test" })
        AutoResume.on_rate_limited("", { rejected = true, source = "test" })
      end)
    end)
  end)

  describe("format_duration", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("formats seconds, minutes and hours", function()
      assert.equals("45s", AutoResume.format_duration(45))
      assert.equals("5m", AutoResume.format_duration(300))
      assert.equals("4h58m", AutoResume.format_duration(17880))
    end)
  end)

  describe("list", function()
    local AutoResume = require("vibing.application.chat.auto_resume")
    local original_load

    -- Stub the store rather than write real files: list() resolves its path through
    -- Git.get_root(nil), which runs git in the *process* cwd — i.e. this repository — so a
    -- filesystem-backed test here would scribble on the developer's own .vibing/.
    before_each(function()
      original_load = PendingResume.load
    end)

    after_each(function()
      PendingResume.load = original_load
    end)

    it("returns pending entries ordered by reset time, soonest first", function()
      PendingResume.load = function()
        return {
          ["/late.md"] = { chat_file_path = "/late.md", resets_at = 2000 },
          ["/soon.md"] = { chat_file_path = "/soon.md", resets_at = 1000 },
        }
      end

      local entries = AutoResume.list()

      assert.equals(2, #entries)
      assert.equals("/soon.md", entries[1].chat_file_path)
      assert.equals("/late.md", entries[2].chat_file_path)
    end)

    it("sorts entries with no reset time last", function()
      PendingResume.load = function()
        return {
          ["/unknown.md"] = { chat_file_path = "/unknown.md" },
          ["/known.md"] = { chat_file_path = "/known.md", resets_at = 1000 },
        }
      end

      local entries = AutoResume.list()

      assert.equals("/known.md", entries[1].chat_file_path)
      assert.equals("/unknown.md", entries[2].chat_file_path)
    end)
  end)

  describe("_may_schedule", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("allows scheduling when no budget is given (explicit :VibingSchedule)", function()
      assert.is_true(AutoResume._may_schedule(nil, nil))
    end)

    it("allows a re-schedule while the budget has room", function()
      assert.is_true(AutoResume._may_schedule(1, 3))
    end)

    it("refuses once the budget is spent", function()
      -- This is the only guard against fire -> rejected -> re-schedule looping forever.
      assert.is_false(AutoResume._may_schedule(3, 3))
    end)

    it("treats a missing retry_count as zero", function()
      assert.is_true(AutoResume._may_schedule(nil, 3))
    end)
  end)

  describe("_is_restorable", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("re-arms a scheduled entry even when auto-resume is disabled", function()
      -- The user asked for this one by hand; the opt-in flag governs unattended resumes only.
      local entry = { chat_file_path = "/a.md", kind = "scheduled", state = "waiting" }
      assert.is_true(AutoResume._is_restorable(entry, { enabled = false }))
    end)

    it("does not re-arm an auto_resume entry when the feature is disabled", function()
      local entry = { chat_file_path = "/a.md", kind = "auto_resume", state = "waiting" }
      assert.is_false(AutoResume._is_restorable(entry, { enabled = false }))
    end)

    it("re-arms an auto_resume entry when the feature is enabled", function()
      local entry = { chat_file_path = "/a.md", state = "waiting" }
      assert.is_true(AutoResume._is_restorable(entry, { enabled = true }))
    end)

    it("never re-arms an in_flight entry, whatever its kind", function()
      assert.is_false(
        AutoResume._is_restorable({ chat_file_path = "/a.md", kind = "scheduled", state = "in_flight" }, { enabled = true })
      )
    end)

    it("never re-arms an entry without a chat file path", function()
      assert.is_false(AutoResume._is_restorable({ kind = "scheduled", state = "waiting" }, { enabled = true }))
    end)
  end)

  describe("schedule_request", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("writes a scheduled entry armed for the requested time", function()
      local chat_path = tmp_root .. "/.vibing/chat/a.md"
      vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")
      local fire_at = os.time() + 3600

      local ok = AutoResume.schedule_request(chat_path, fire_at, { limit_type = "five_hour" })
      assert.is_true(ok)

      local entry = PendingResume.get(chat_path)
      assert.is_not_nil(entry)
      assert.equals("scheduled", entry.kind)
      assert.equals(fire_at, entry.resets_at)
      assert.equals("five_hour", entry.limit_type)
      assert.equals("waiting", entry.state)

      AutoResume.cancel(chat_path)
    end)

    it("refuses when the re-schedule budget is spent", function()
      local chat_path = tmp_root .. "/.vibing/chat/b.md"
      vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")

      local ok, reason = AutoResume.schedule_request(chat_path, os.time() + 60, { retry_count = 3, max_retries = 3 })
      assert.is_false(ok)
      assert.is_string(reason)
      assert.is_nil(PendingResume.get(chat_path))
    end)

    it("refuses a fire time far enough out to be implausible", function()
      -- Same 8-day ceiling auto-resume uses: a timer armed for months means a misread payload.
      local chat_path = tmp_root .. "/.vibing/chat/c.md"
      vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")

      local ok = AutoResume.schedule_request(chat_path, os.time() + 30 * 24 * 3600, {})
      assert.is_false(ok)
      assert.is_nil(PendingResume.get(chat_path))
    end)
  end)

  describe("_scheduled_decision", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("sends when a body is waiting and the chat is idle", function()
      assert.equals("send", AutoResume._scheduled_decision("do the thing", false))
    end)

    it("drops when the chat is already sending", function()
      local action = AutoResume._scheduled_decision("do the thing", true)
      assert.equals("drop", action)
    end)

    it("drops when the body was deleted while the chat was parked", function()
      -- The body lives in the buffer, so the user can remove it. Sending an empty message, or
      -- the generic continuation prompt, would both be wrong.
      local action, reason = AutoResume._scheduled_decision(nil, false)
      assert.equals("drop", action)
      assert.is_string(reason)
    end)

    it("drops when the body is only whitespace", function()
      assert.equals("drop", AutoResume._scheduled_decision("   \n  ", false))
    end)

    it("returns no reason on a send verdict", function()
      local action, reason = AutoResume._scheduled_decision("do the thing", false)
      assert.equals("send", action)
      assert.is_nil(reason)
    end)

    it("prioritises the is_sending check over an empty body", function()
      -- Both conditions hold here; the reason should name the actual guard that fired first.
      local action, reason = AutoResume._scheduled_decision(nil, true)
      assert.equals("drop", action)
      assert.equals("the chat is already sending a request", reason)
    end)
  end)

  describe("fire() kind dispatch (behavioural)", function()
    local AutoResume = require("vibing.application.chat.auto_resume")
    local Config = require("vibing.config")
    local original_get

    before_each(function()
      original_get = Config.get
      -- The defect under test is a "scheduled" entry reaching the auto_resume opts.enabled gate.
      -- Falsy enabled is the default and the exact condition restore() re-arms scheduled entries
      -- under, so it is the only config that distinguishes correct dispatch from the regression.
      Config.get = function()
        return { agent = { auto_resume_on_limit = { enabled = false } } }
      end
    end)

    after_each(function()
      Config.get = original_get
    end)

    it("routes a scheduled entry to fire_scheduled instead of the auto_resume enabled gate", function()
      -- A path that can't exist on disk forces fire_scheduled() down its
      -- resolve_chat_buffer-failure branch, which removes the entry and warns. If the dispatch
      -- were ever moved below `if not opts.enabled then`, this entry would instead be removed
      -- *silently* by that gate — same removal, no warning — which is exactly what this test
      -- must catch and the deleted source-position test could not.
      local chat_path = tmp_root .. "/does-not-exist.md"
      local entry = {
        chat_file_path = chat_path,
        kind = "scheduled",
        resets_at = os.time() + 60,
        retry_count = 0,
        recorded_at = os.time(),
        state = "waiting",
      }
      PendingResume.put(entry)

      local original_notify = vim.notify
      local messages = {}
      vim.notify = function(msg, ...)
        table.insert(messages, msg)
      end

      -- Restore the real vim.notify before asserting, so a failed assertion here can never leave
      -- the stub installed for the rest of the suite.
      local ok, err = pcall(AutoResume._fire, chat_path, entry)
      vim.notify = original_notify
      assert.is_true(ok, err)

      local found = false
      for _, msg in ipairs(messages) do
        if msg:match("Scheduled request skipped for") then
          found = true
          break
        end
      end
      assert.is_true(found, "expected a 'Scheduled request skipped for' notification; got: " .. vim.inspect(messages))
      assert.is_nil(PendingResume.get(chat_path))
    end)
  end)
end)
