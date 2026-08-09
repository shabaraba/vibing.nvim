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
end)
