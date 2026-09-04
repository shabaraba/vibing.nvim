describe("auto_compact", function()
  local AutoCompact = require("vibing.application.chat.auto_compact")
  local Timestamp = require("vibing.core.utils.timestamp")

  local ON = { enabled = true, at = 200000 }

  describe("should_compact", function()
    it("inserts a compaction once the last turn reached the threshold", function()
      assert.is_true(AutoCompact.should_compact(ON, "claude", 200000, "keep going", false))
      assert.is_true(AutoCompact.should_compact(ON, "claude", 310000, "keep going", false))
    end)

    it("does nothing below it", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", 199999, "keep going", false))
    end)

    it("is off by default", function()
      assert.is_false(AutoCompact.should_compact({}, "claude", 310000, "keep going", false))
      assert.is_false(AutoCompact.should_compact({ enabled = false, at = 200000 }, "claude", 310000, "x", false))
    end)

    it("skips the send right after a compaction, so a compaction that did not shrink cannot loop", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", 310000, "keep going", true))
    end)

    -- `/compact` is a Claude CLI command. Everywhere else it would arrive as a line of prose.
    it("only applies to the claude backend", function()
      for _, agent in ipairs({ "codex", "copilot", "grok" }) do
        assert.is_false(AutoCompact.should_compact(ON, agent, 310000, "keep going", false))
      end
    end)

    it("leaves slash commands and approval answers alone", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", 310000, "/model opus", false))
      local answer = "1. allow_once - Allow this execution only"
      assert.is_false(AutoCompact.should_compact(ON, "claude", 310000, answer, false))
    end)

    it("needs a message to send", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", 310000, "", false))
      assert.is_false(AutoCompact.should_compact(ON, "claude", 310000, "   \n  ", false))
    end)

    -- A chat that has never reported a turn has no size on record; guessing one would be worse
    -- than waiting for the first `### Tokens` section.
    it("waits for a measurement rather than assuming one", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", nil, "keep going", false))
    end)

    it("treats at <= 0 as off, matching how warn_context = 0 silences the warning", function()
      assert.is_false(AutoCompact.should_compact({ enabled = true, at = 0 }, "claude", 900000, "x", false))
      assert.is_false(AutoCompact.should_compact({ enabled = true, at = -1 }, "claude", 900000, "x", false))
    end)

    it("falls back to the shared default when at is unset", function()
      local TokenUsage = require("vibing.core.utils.token_usage")
      local opts = { enabled = true }

      assert.is_true(AutoCompact.should_compact(opts, "claude", TokenUsage.DEFAULT_AUTO_COMPACT_AT, "x", false))
      assert.is_false(AutoCompact.should_compact(opts, "claude", TokenUsage.DEFAULT_AUTO_COMPACT_AT - 1, "x", false))
    end)
  end)

  -- A limit is both the worst moment to spend a turn on compaction and an actively harmful one:
  -- `_try_schedule_instead_of_send` exempts slash commands, so the `/compact` would be sent,
  -- rejected, and its own text written into `_pending_user_text` over the parked body.
  describe("_limit_active", function()
    local LimitState = require("vibing.infrastructure.storage.limit_state")
    local dir, buf

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, dir .. "/chat.md")
    end)

    after_each(function()
      pcall(LimitState.clear, dir)
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      vim.fn.delete(dir, "rf")
    end)

    it("reports no limit when nothing is on record", function()
      assert.is_false(AutoCompact._limit_active(buf, "claude"))
    end)

    it("reports the limit recorded for this chat's backend", function()
      LimitState.record({ resets_at = os.time() + 3600 }, dir, "claude")

      assert.is_true(AutoCompact._limit_active(buf, "claude"))
    end)

    it("ignores another backend's limit, which this chat is not waiting on", function()
      LimitState.record({ resets_at = os.time() + 3600 }, dir, "codex")

      assert.is_false(AutoCompact._limit_active(buf, "claude"))
    end)

    it("reports no limit for a chat that has never been saved", function()
      local unsaved = vim.api.nvim_create_buf(false, true)
      assert.is_false(AutoCompact._limit_active(unsaved, "claude"))
      vim.api.nvim_buf_delete(unsaved, { force = true })
    end)
  end)

  describe("compact_prompt", function()
    it("sends the bare command when no focus is configured", function()
      assert.equals("/compact", AutoCompact.compact_prompt(nil))
      assert.equals("/compact", AutoCompact.compact_prompt("   "))
    end)

    it("passes the focus through, since what the summary keeps decides the next turns' quality", function()
      assert.equals("/compact keep the open tasks", AutoCompact.compact_prompt("keep the open tasks"))
    end)
  end)

  describe("_rewrite_unsent_body", function()
    local buf

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    local function lines()
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end

    it("replaces the body and leaves the header where it was", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        Timestamp.create_header("User", "2026-09-04 10:00:00"),
        "",
        "earlier message",
        "",
        Timestamp.create_unsent_user_header(),
        "",
        "please continue",
        "",
      })

      assert.is_true(AutoCompact._rewrite_unsent_body(buf, "/compact"))

      local after = lines()
      assert.equals(Timestamp.create_unsent_user_header(), after[5])
      assert.equals("/compact", after[7])
      assert.is_false(vim.tbl_contains(after, "please continue"))
      -- Only the trailing section is touched; the transcript above it is history.
      assert.is_true(vim.tbl_contains(after, "earlier message"))
    end)

    -- The header carries the section kind and sender, so rebuilding it as `## User` would erase
    -- who the turn is for.
    it("keeps a delivered section's kind and sender", function()
      local header = Timestamp.create_header("Request", nil, ".vibing/chat/orchestrator.md")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { header, "", "do the thing", "" })

      assert.is_true(AutoCompact._rewrite_unsent_body(buf, "/compact focus"))
      assert.equals(header, lines()[1])
      assert.equals("/compact focus", lines()[3])
    end)

    it("refuses when the trailing section has already been sent", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        Timestamp.create_header("User", "2026-09-04 10:00:00"),
        "",
        "already sent",
        "",
      })

      assert.is_false(AutoCompact._rewrite_unsent_body(buf, "/compact"))
      assert.equals("already sent", lines()[3])
    end)

    it("refuses when there is no section at all", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "vibing.nvim: true", "---", "" })

      assert.is_false(AutoCompact._rewrite_unsent_body(buf, "/compact"))
    end)
  end)
end)
