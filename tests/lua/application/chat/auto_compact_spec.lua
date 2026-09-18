describe("auto_compact", function()
  local AutoCompact = require("vibing.application.chat.auto_compact")
  local Timestamp = require("vibing.core.utils.timestamp")

  local ON = { enabled = true, at = 200000 }

  describe("should_compact", function()
    it("inserts a compaction once the last turn reached the threshold", function()
      assert.is_true(AutoCompact.should_compact(ON, "claude", 200000, false))
      assert.is_true(AutoCompact.should_compact(ON, "claude", 310000, false))
    end)

    it("does nothing below it", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", 199999, false))
    end)

    it("is off by default", function()
      assert.is_false(AutoCompact.should_compact({}, "claude", 310000, false))
      assert.is_false(AutoCompact.should_compact({ enabled = false, at = 200000 }, "claude", 310000, false))
    end)

    it("skips the send right after a compaction, so a compaction that did not shrink cannot loop", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", 310000, true))
    end)

    -- `/compact` is a Claude CLI command. Everywhere else it would arrive as a line of prose.
    it("only applies to the claude backend", function()
      for _, agent in ipairs({ "codex", "copilot", "grok" }) do
        assert.is_false(AutoCompact.should_compact(ON, agent, 310000, false))
      end
    end)

    -- A chat that has never reported a turn has no size on record; guessing one would be worse
    -- than waiting for the first `### Tokens` section.
    it("waits for a measurement rather than assuming one", function()
      assert.is_false(AutoCompact.should_compact(ON, "claude", nil, false))
    end)

    it("treats at <= 0 as off, matching how warn_context = 0 silences the warning", function()
      assert.is_false(AutoCompact.should_compact({ enabled = true, at = 0 }, "claude", 900000, false))
      assert.is_false(AutoCompact.should_compact({ enabled = true, at = -1 }, "claude", 900000, false))
    end)

    it("falls back to the shared default when at is unset", function()
      local TokenUsage = require("vibing.core.utils.token_usage")
      local opts = { enabled = true }

      assert.is_true(AutoCompact.should_compact(opts, "claude", TokenUsage.DEFAULT_AUTO_COMPACT_AT, false))
      assert.is_false(AutoCompact.should_compact(opts, "claude", TokenUsage.DEFAULT_AUTO_COMPACT_AT - 1, false))
    end)

    -- The slash-command and approval-answer exclusions live in `ChatBuffer:can_defer_send`, which
    -- `before_manual_send` consults. Three interceptions now share the `<CR>` path and all three
    -- need that same judgement; a second copy here is how one of them stops agreeing.
    it("leaves the message-shaped exclusions to can_defer_send", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local chat = setmetatable({ buf = buf }, { __index = require("vibing.presentation.chat.buffer") })

      assert.is_false(chat:can_defer_send("/model opus"))
      assert.is_true(chat:can_defer_send("keep going"))

      vim.api.nvim_buf_delete(buf, { force = true })
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

  -- The parked message is written back by `on_response_done`, not handed to
  -- `set_pending_user_text` -- `addUserSection` renders pending text, question lists and approval
  -- prompts into the same unsent section, so a stop the user has to clear must hold the message
  -- back rather than land next to the prompt.
  describe("resume_decision", function()
    it("releases the message on an ordinary finish", function()
      assert.equals("send", AutoCompact.resume_decision(nil))
    end)

    -- A wasted turn is not a reason to swallow what the user typed.
    it("releases it after a failed compaction too", function()
      assert.equals("send", AutoCompact.resume_decision("error"))
    end)

    it("holds it while the chat is waiting on the user", function()
      assert.equals("wait", AutoCompact.resume_decision("waiting_approval"))
      assert.equals("wait", AutoCompact.resume_decision("asked_question"))
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

  -- A delivery from another chat is the turn that wakes an orchestrator, and the one turn the
  -- `<CR>` hook never saw. Over the threshold it sends `/compact` *instead of* the delivery and
  -- says so; the caller keeps the message for the turn after.
  describe("before_delivery", function()
    local Config = require("vibing.config")
    local view = require("vibing.presentation.chat.view")
    local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
    local ChatBuffer = require("vibing.presentation.chat.buffer")
    local TokenUsage = require("vibing.core.utils.token_usage")

    local originals, sends, buf, chat

    --- @param context number
    --- @return string[]
    local function tokens_section(context)
      local acc = TokenUsage.new()
      TokenUsage.record(acc, { input_tokens = context })
      return vim.split(TokenUsage.section(acc, 150000), "\n", { plain = true })
    end

    --- A chat whose last turn reported `context`, ending in an empty unsent section.
    --- @param context number?
    --- @param unsent string?
    local function make_chat(context, unsent)
      local lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        Timestamp.create_header("User", "2026-09-04 10:00:00"),
        "",
        "earlier question",
        "",
        Timestamp.create_header("Assistant", "2026-09-04 10:00:30"),
        "",
        "an answer",
        "",
      }
      if context then
        vim.list_extend(lines, tokens_section(context))
      end
      vim.list_extend(lines, { Timestamp.create_unsent_user_header(), "", unsent or "", "" })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    --- @param opts table? overrides for agent.token_usage.auto_compact
    local function configure(opts)
      Config.get = function()
        return {
          adapter = "claude",
          agent = { token_usage = { auto_compact = vim.tbl_extend("force", { enabled = true, at = 200000 }, opts or {}) } },
        }
      end
    end

    before_each(function()
      originals = {
        get = Config.get,
        get_chat_buffer = view.get_chat_buffer,
        send = ProgrammaticSender.send,
        notify = vim.notify,
      }
      sends = {}
      buf = vim.api.nvim_create_buf(false, true)
      chat = setmetatable({ buf = buf }, ChatBuffer)
      AutoCompact.forget(buf)

      configure()
      view.get_chat_buffer = function(bufnr)
        return bufnr == buf and chat or nil
      end
      ProgrammaticSender.send = function(bufnr, message, sender, section)
        table.insert(sends, { bufnr = bufnr, message = message, sender = sender, section = section })
        return { success = true, bufnr = bufnr }
      end
      vim.notify = function() end
    end)

    after_each(function()
      Config.get = originals.get
      view.get_chat_buffer = originals.get_chat_buffer
      ProgrammaticSender.send = originals.send
      vim.notify = originals.notify
      AutoCompact.forget(buf)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("runs /compact instead of the delivery once the chat is over the threshold", function()
      make_chat(205000)

      assert.is_true(AutoCompact.before_delivery(buf, { kind = "Report" }))

      assert.equals(1, #sends)
      assert.equals("/compact", sends[1].message)
      -- A plain `## User` turn: the delivery's own header names who the turn is from, and the
      -- compaction is from nobody.
      assert.is_nil(sends[1].section)
    end)

    it("passes the configured focus through, as the manual path does", function()
      configure({ focus = "the open tasks" })
      make_chat(205000)

      assert.is_true(AutoCompact.before_delivery(buf))
      assert.equals("/compact the open tasks", sends[1].message)
    end)

    it("lets the delivery through below the threshold, and when the feature is off", function()
      make_chat(199999)
      assert.is_false(AutoCompact.before_delivery(buf))

      configure({ enabled = false })
      make_chat(900000)
      assert.is_false(AutoCompact.before_delivery(buf))

      assert.equals(0, #sends)
    end)

    it("does not spend a turn on a chat that has never reported a size", function()
      make_chat(nil)
      assert.is_false(AutoCompact.before_delivery(buf))
      assert.equals(0, #sends)
    end)

    -- The compaction turn's own `### Tokens` still reports the pre-compaction size, so without
    -- the cooldown the re-entry from `flush` would compact again instead of delivering.
    it("lets the very next delivery through on the cooldown", function()
      make_chat(205000)
      assert.is_true(AutoCompact.before_delivery(buf))

      make_chat(205000)
      assert.is_false(AutoCompact.before_delivery(buf))
      assert.equals(1, #sends, "the second call must be the delivery, not another /compact")

      -- And the cooldown is spent by that one delivery, not held forever.
      make_chat(205000)
      assert.is_true(AutoCompact.before_delivery(buf))
    end)

    it("leaves the delivery alone when the compaction could not be sent", function()
      ProgrammaticSender.send = function(bufnr)
        return { success = false, bufnr = bufnr }
      end
      make_chat(205000)

      assert.is_false(AutoCompact.before_delivery(buf))
      -- No cooldown was taken for a compaction that did not run.
      ProgrammaticSender.send = function(bufnr, message)
        table.insert(sends, { message = message })
        return { success = true, bufnr = bufnr }
      end
      assert.is_true(AutoCompact.before_delivery(buf))
    end)

    -- One cooldown per chat, whichever path spends it: a delivery's compaction must stop the
    -- user's next `<CR>` from compacting again, and vice versa.
    it("shares the cooldown with the manual path", function()
      make_chat(205000)
      assert.is_true(AutoCompact.before_delivery(buf))

      make_chat(205000, "keep going")
      assert.is_false(AutoCompact.before_manual_send(chat))
      assert.equals("keep going", vim.trim(chat:extract_user_message()))

      make_chat(205000, "and again")
      assert.is_true(AutoCompact.before_manual_send(chat), "the delivery spent the cooldown, so this one compacts")
      AutoCompact.forget(buf)

      make_chat(205000, "once more")
      assert.is_true(AutoCompact.before_manual_send(chat))
      make_chat(205000)
      assert.is_false(AutoCompact.before_delivery(buf), "the manual compaction is what this delivery rides on")
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
