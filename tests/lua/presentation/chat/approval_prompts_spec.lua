---@diagnostic disable: undefined-field
--- Several tool-approval prompts open on one chat at the same time.
---
--- Not a corner case: measured on claude 2.1.236, one turn's three Reads started three PreToolUse
--- hooks 0.54s apart and all three blocked simultaneously (`tests/perf/hook_concurrency.sh`). Once
--- an approval is answered without killing the CLI, every one of those hooks is a prompt waiting
--- for its own answer, and the numbered lists they draw are identical — so an answer is attributed
--- by the `<!-- vibing:req=... -->` marker on the line the user kept, never by position.
local ChatBuffers = require("tests.helpers.chat_buffers")

describe("several approval prompts at once", function()
  local view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
  end)

  after_each(function()
    ChatBuffers.reset()
  end)

  --- @return Vibing.ChatBuffer
  local function chat_with(prompts)
    local chat_buf = view.render({ session_id = "approvals" }, "back")
    for _, prompt in ipairs(prompts) do
      chat_buf:insert_approval_request(prompt.tool, prompt.input or {}, prompt.options or {
        { value = "allow_once", label = "allow_once - Allow this execution only" },
        { value = "deny_once", label = "deny_once - Deny this execution only" },
      }, prompt.request_id)
    end
    return chat_buf
  end

  describe("holding them", function()
    it("keeps every prompt, rather than the newest replacing the last", function()
      -- Dropping the first would leave its hook blocked with nobody able to answer it, until the
      -- wait limit denied it on the user's behalf.
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      local pending = chat_buf:get_pending_approvals()
      assert.equals(2, #pending)
      assert.equals("req-1", pending[1].request_id)
      assert.equals("req-2", pending[2].request_id)
    end)

    it("updates in place when the same hook asks again", function()
      -- copilot re-runs a hook it cut, with the same tool but a new invocation. Two prompts for
      -- one blocked hook would mean one of them could never be answered.
      local chat_buf = chat_with({
        { tool = "Bash", input = { command = "old" }, request_id = "req-1" },
        { tool = "Bash", input = { command = "new" }, request_id = "req-1" },
      })

      local pending = chat_buf:get_pending_approvals()
      assert.equals(1, #pending)
      assert.equals("new", pending[1].input.command)
    end)

    it("hands out one prompt by name", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      assert.equals("Write", chat_buf:get_pending_approval("req-2").tool)
      assert.is_nil(chat_buf:get_pending_approval("req-9"))
    end)

    it("refuses to guess which one when asked without a name", function()
      -- The unnamed form is the old single-slot API. It stays usable while there is exactly one
      -- prompt, and answers nil rather than picking for the caller once there are more.
      local one = chat_with({ { tool = "Bash", request_id = "req-1" } })
      assert.equals("Bash", one:get_pending_approval().tool)

      local two = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      assert.is_nil(two:get_pending_approval())
    end)

    it("clears only the prompt that was answered", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      assert.is_true(chat_buf:clear_pending_approval("req-1"))

      local pending = chat_buf:get_pending_approvals()
      assert.equals(1, #pending)
      assert.equals("req-2", pending[1].request_id)
    end)

    it("hands out copies, so the one place that may spend a prompt stays the only one", function()
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      chat_buf:get_pending_approvals()[1].tool = "mutated"
      assert.equals("Bash", chat_buf:get_pending_approval("req-1").tool)
    end)
  end)

  describe("expiry", function()
    it("marks the prompt instead of deleting it", function()
      -- The user may be editing this buffer right now. Removing lines moves everything below them
      -- under the cursor; a mark they can read is what explains the refusal.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      assert.is_true(chat_buf:mark_approval_expired("req-1"))

      local pending = chat_buf:get_pending_approvals()
      assert.equals(1, #pending, "the prompt stays in the list")
      assert.is_true(pending[1].expired)
    end)

    it("reports when there was nothing to mark", function()
      assert.is_false(chat_with({}):mark_approval_expired("req-1"))
    end)

    it("refuses to spend an expired prompt", function()
      -- Its `.res` already carries a deny and its hook is released; consuming it now would record
      -- a grant for a tool call that was already refused.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:mark_approval_expired("req-1")

      local ApprovalDecision = require("vibing.application.chat.approval_decision")
      local consumed, err = ApprovalDecision.consume(chat_buf, { action = "allow_once", request_id = "req-1" })

      assert.is_nil(consumed)
      assert.is_truthy(tostring(err):find("expired", 1, true), tostring(err))
      assert.same({}, chat_buf:get_session_allow())
    end)
  end)

  describe("expiry reaching the user", function()
    local Pending = require("vibing.infrastructure.rpc.pending_approvals")
    local Permission = require("vibing.infrastructure.rpc.handlers.permission")

    local function buffer_text(chat_buf)
      return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
    end

    it("marks the prompt and says so in the chat, in one call", function()
      -- Either half alone is a trap: a silent mark makes the user answer a prompt that will be
      -- refused, and a notice without the mark leaves the prompt answerable against a hook that is
      -- no longer waiting.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      assert.is_true(chat_buf:expire_approval({ request_id = "req-1", tool = "Bash" }))

      assert.is_true(chat_buf:get_pending_approvals()[1].expired)
      local text = buffer_text(chat_buf)
      assert.is_truthy(text:find("Tool approval expired", 1, true), text)
      assert.is_truthy(text:find("Bash", 1, true), text)
    end)

    it("keeps one line per expiry rather than rewriting the last", function()
      -- Prompts expire independently — three hooks blocking at once is measured, not hypothetical —
      -- so a second expiry erasing the first would hide one of them.
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      chat_buf:expire_approval({ request_id = "req-1", tool = "Bash" })
      chat_buf:expire_approval({ request_id = "req-2", tool = "Write" })

      local text = buffer_text(chat_buf)
      local _, count = text:gsub("Tool approval expired", "")
      assert.equals(2, count, text)
    end)

    it("reaches the chat that was asked, and no other", function()
      local asked = chat_with({ { tool = "Bash", request_id = "req-1" } })
      local other = chat_with({ { tool = "Bash", request_id = "req-9" } })

      assert.is_true(Permission._on_approval_expired({
        request_id = "req-1",
        tool = "Bash",
        chat_bufnr = asked.buf,
      }))

      assert.is_true(asked:get_pending_approvals()[1].expired)
      assert.is_false(other:get_pending_approvals()[1].expired == true)
      assert.is_nil(buffer_text(other):find("Tool approval expired", 1, true))
    end)

    it("says no when the chat is gone", function()
      assert.is_false(Permission._on_approval_expired({ request_id = "req-1", chat_bufnr = 999999 }))
      assert.is_false(Permission._on_approval_expired({ request_id = "req-1" }))
    end)

    it("is what the wait limit actually runs, end to end", function()
      -- The registry writes the deny itself; this asserts the other half — that the callback the
      -- `ask` branch hands it is the one that tells the user.
      local comm_dir = vim.fn.tempname()
      vim.fn.mkdir(comm_dir, "p")
      vim.env.VIBING_HOOK_COMM_DIR = comm_dir
      Pending._reset()

      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      local ok, err = pcall(function()
        Pending.open({
          request_id = "req-1",
          chat_bufnr = chat_buf.buf,
          tool = "Bash",
          on_timeout = Permission._on_approval_expired,
        })

        assert.is_true(Pending.expire("req-1"))

        local f = assert(io.open(comm_dir .. "/req-1.res", "r"), "the expiring hook was never answered")
        local decoded = vim.json.decode(f:read("*a"))
        f:close()
        assert.equals("deny", decoded.hookSpecificOutput.permissionDecision)

        assert.is_true(chat_buf:get_pending_approvals()[1].expired)
        assert.is_truthy(buffer_text(chat_buf):find("Tool approval expired", 1, true))
      end)

      Pending._reset()
      vim.env.VIBING_HOOK_COMM_DIR = nil
      vim.fn.delete(comm_dir, "rf")
      assert.is_true(ok, tostring(err))
    end)
  end)

  describe("what the buffer shows", function()
    local function rendered(chat_buf)
      chat_buf:add_user_section()
      return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
    end

    it("draws every prompt, each option line carrying its own request", function()
      local text = rendered(chat_with({
        { tool = "Bash", input = { command = "ls" }, request_id = "req-1" },
        { tool = "Write", input = { file_path = "/tmp/x" }, request_id = "req-2" },
      }))

      assert.is_truthy(text:find("Tool: Bash", 1, true))
      assert.is_truthy(text:find("Tool: Write", 1, true))
      assert.is_truthy(text:find("1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->", 1, true), text)
      assert.is_truthy(text:find("1. allow_once - Allow this execution only <!-- vibing:req=req-2 -->", 1, true), text)
    end)

    it("says an expired prompt is expired and offers it no options", function()
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:mark_approval_expired("req-1")

      local text = rendered(chat_buf)
      assert.is_truthy(text:find("expired", 1, true), text)
      assert.is_nil(text:find("vibing:req=req-1", 1, true), "an expired prompt must not offer an answer")
    end)
  end)

  describe("answering", function()
    --- Render the prompts, then leave behind exactly the lines given — which is what the user does
    --- with `dd`. Appending instead would leave every drawn option line in the section, and
    --- `extract_user_message` reads the whole section, so the send would be ambiguous for a reason
    --- that has nothing to do with what is under test.
    --- @param chat_buf Vibing.ChatBuffer
    --- @param answer_lines string[]
    local function type_and_send(chat_buf, answer_lines)
      chat_buf:add_user_section()

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      local header
      for index = #lines, 1, -1 do
        if lines[index]:match("^## User") then
          header = index
          break
        end
      end
      assert.is_not_nil(header, "the prompt must have been drawn into a user section")

      local kept = { "" }
      vim.list_extend(kept, answer_lines)
      vim.api.nvim_buf_set_lines(chat_buf.buf, header, -1, false, kept)

      return chat_buf:send_message()
    end

    it("spends exactly the prompt the kept line names", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      type_and_send(chat_buf, { "2. deny_once - Deny this execution only <!-- vibing:req=req-2 -->" })

      assert.is_nil(chat_buf:get_pending_approval("req-2"), "the answered prompt is spent")
      assert.is_not_nil(chat_buf:get_pending_approval("req-1"), "the other prompt is untouched")
      assert.is_truthy(vim.tbl_contains(chat_buf:get_session_deny(), "Write:once"))
    end)

    --- Refusals reach the user through `vim.notify`, which is what the approval path has always
    --- used for this. Captured rather than asserted on the buffer: an explanation written into the
    --- unsent section would be extracted as part of the next message and sent to the model.
    --- @param fn function
    --- @return string[] messages
    local function captured_notifications(fn)
      local messages = {}
      local original = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(message, level, ...)
        table.insert(messages, { text = tostring(message), level = level })
        return original(message, level, ...)
      end
      local ok, err = pcall(fn)
      vim.notify = original
      assert.is_true(ok, tostring(err))

      local texts = {}
      for _, entry in ipairs(messages) do
        -- At least WARN, always. Mixed in with informational notices, a notification plugin's
        -- own filtering can drop it — and a dropped refusal is the silent <CR> again.
        assert.is_true(
          (entry.level or 0) >= vim.log.levels.WARN,
          "a refusal must not be an informational notice: " .. entry.text
        )
        table.insert(texts, entry.text)
      end
      return texts
    end

    it("tells the user which request has how many lines left", function()
      -- Half of "refuse when ambiguous" is the refusal; the other half is the user being able to
      -- read why. Without it the feature is indistinguishable from "<CR> sometimes does nothing",
      -- which is worse than the behaviour it replaced.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      local messages = captured_notifications(function()
        type_and_send(chat_buf, {
          "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
          "2. deny_once - Deny this execution only <!-- vibing:req=req-1 -->",
        })
      end)

      local joined = table.concat(messages, "\n")
      assert.is_truthy(joined:find("req-1", 1, true), "the refusal must name the request: " .. joined)
      assert.is_truthy(joined:find("2 option lines", 1, true), "and how many lines are left: " .. joined)
      assert.is_truthy(joined:find("delete all but", 1, true), "and what to do about it: " .. joined)
    end)

    it("leaves the explanation in the buffer, where a missed notification cannot hide it", function()
      -- A notification disappears. If it is the only channel and the user looks away, the buffer
      -- is byte-identical to before they pressed <CR> — which is the "nothing happened" reading
      -- the refusal exists to avoid.
      --
      -- Writing it there is safe for the same reason the expired marker is: it lands inside the
      -- block we draw, alongside the option lines, all of which `extract_user_message` already
      -- returns. Measured, not assumed.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      type_and_send(chat_buf, {
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
        "2. deny_once - Deny this execution only <!-- vibing:req=req-1 -->",
      })

      local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
      assert.is_truthy(text:find("not applied", 1, true), "the buffer must say the answer was refused")
      assert.is_truthy(text:find("req-1", 1, true), "and which request: " .. text)
    end)

    it("replaces the previous explanation rather than stacking them up", function()
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      local ambiguous = {
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
        "2. deny_once - Deny this execution only <!-- vibing:req=req-1 -->",
      }

      type_and_send(chat_buf, ambiguous)
      type_and_send(chat_buf, ambiguous)

      local count = 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
        if line:find("not applied", 1, true) then
          count = count + 1
        end
      end
      assert.equals(1, count, "pressing <CR> twice must not leave two explanations")
    end)

    it("tells the user to keep a marker when several prompts are open", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      local messages = captured_notifications(function()
        type_and_send(chat_buf, { "1. allow_once - Allow this execution only" })
      end)

      local joined = table.concat(messages, "\n")
      assert.is_truthy(joined:find("vibing:req", 1, true), "the refusal must say how to fix it: " .. joined)
      assert.is_truthy(joined:find("2 approval", 1, true), joined)
    end)

    it("refuses an ambiguous answer without spending anything", function()
      -- Pressing <CR> with the whole block still there used to take the first line, which is
      -- always `allow_once` — a grant produced by doing nothing. Refusing is cheap now: the hook
      -- is still blocked, so the user edits the lines and presses <CR> again.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      local sent = type_and_send(chat_buf, {
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
        "2. deny_once - Deny this execution only <!-- vibing:req=req-1 -->",
      })

      assert.is_false(sent)
      assert.is_not_nil(chat_buf:get_pending_approval("req-1"), "nothing may be spent")
      assert.same({}, chat_buf:get_session_allow())
    end)

    it("refuses an unmarked line while several prompts are open", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })

      local sent = type_and_send(chat_buf, { "1. allow_once - Allow this execution only" })

      assert.is_false(sent)
      assert.equals(2, #chat_buf:get_pending_approvals())
    end)

    it("still takes an unmarked line when only one prompt is open", function()
      -- The single-prompt shape every existing chat has. Nothing about it changes.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })

      type_and_send(chat_buf, { "1. allow_once - Allow this execution only" })

      assert.is_nil(chat_buf:get_pending_approval("req-1"))
      assert.is_truthy(vim.tbl_contains(chat_buf:get_session_allow(), "Bash:once"))
    end)

    it("does not sweep away the :once grant the answer just created", function()
      -- The `_once_tools` safety net clears grants left over from the previous turn. Moving the
      -- answer above `cancel_request()` put it *after* that sweep, so `allow_once` was recorded
      -- and wiped in the same keypress — visible only by reading the session list, since the send
      -- itself succeeds.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf._session_allow = { "Write:once" }
      chat_buf._once_tools = { "Write:once" }

      type_and_send(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" })

      local allow = chat_buf:get_session_allow()
      assert.is_truthy(vim.tbl_contains(allow, "Bash:once"), "the new grant must survive: " .. vim.inspect(allow))
      assert.is_false(vim.tbl_contains(allow, "Write:once"), "the previous turn's grant must be gone")
    end)

    it("refuses an answer to a prompt that already expired", function()
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:mark_approval_expired("req-1")

      local sent = type_and_send(chat_buf, {
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
      })

      assert.is_false(sent)
      assert.same({}, chat_buf:get_session_allow())
    end)
  end)

  describe("output while a prompt is open", function()
    --- An append-only buffer cannot hold an input field and a stream of output at the same time.
    --- The prompt is an unsent `## User` section at the end, and `flush_chunks` appends at the end
    --- too — so anything flushed while a prompt is open lands *under* the input, where
    --- `extract_user_message` reads it as the user's next message.
    local Pending = require("vibing.infrastructure.rpc.pending_approvals")
    local comm_dir

    --- Without a registry entry the answer is not answered *in place* at all: it falls through to
    --- `retry_as_new_turn`, which starts a real send. That path also opens a `## Assistant` and
    --- returns true, so a case that only checked the return value would be green while testing
    --- something else entirely.
    --- `chat_bufnr` is not decoration: "is this chat still holding a hook" is asked of the registry
    --- by buffer, so an entry filed under no chat holds nothing and this whole describe would pass
    --- by testing the unheld case.
    local function blocked_on(chat_buf, request_ids)
      for _, request_id in ipairs(request_ids) do
        Pending.open({ request_id = request_id, chat_bufnr = chat_buf.buf, tool = "Bash" })
      end
      assert.equals(#request_ids, #Pending.list_for_chat(chat_buf.buf))
    end

    before_each(function()
      comm_dir = vim.fn.tempname()
      vim.fn.mkdir(comm_dir, "p")
      vim.env.VIBING_HOOK_COMM_DIR = comm_dir
      Pending._reset()
    end)

    after_each(function()
      Pending._reset()
      vim.env.VIBING_HOOK_COMM_DIR = nil
      vim.fn.delete(comm_dir, "rf")
    end)

    local function text(chat_buf)
      return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
    end

    local function line_index(chat_buf, needle)
      for index, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
        if line:find(needle, 1, true) then
          return index
        end
      end
      return nil
    end

    --- The user's `<CR>` on a prompt already drawn mid-turn: keep the lines given, drop the rest of
    --- the section. Unlike `type_and_send` above it does not draw the section first — that has
    --- already happened, which is the whole point of these cases.
    local function answer(chat_buf, answer_lines)
      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      local header
      for index = #lines, 1, -1 do
        if lines[index]:match("^## User") then
          header = index
          break
        end
      end
      assert.is_not_nil(header, "the prompt should already be drawn:\n" .. text(chat_buf))

      local kept = { "" }
      vim.list_extend(kept, answer_lines)
      vim.api.nvim_buf_set_lines(chat_buf.buf, header, -1, false, kept)
      return chat_buf:send_message()
    end

    it("streams normally when nothing is waiting for an answer", function()
      -- The control for every case below: without it, "the text never appeared" would be green
      -- whether the hold worked or the harness simply never flushes anything.
      local chat_buf = chat_with({})
      chat_buf:start_response()
      chat_buf:append_chunk("ordinary output\n")

      vim.wait(200, function()
        return line_index(chat_buf, "ordinary output") ~= nil
      end)
      assert.is_not_nil(line_index(chat_buf, "ordinary output"), text(chat_buf))
    end)

    it("holds it while a prompt is open", function()
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()
      chat_buf:append_chunk("a parallel tool's result\n")

      vim.wait(200)
      assert.is_nil(line_index(chat_buf, "a parallel tool's result"), text(chat_buf))
    end)

    it("does not hold for a drawn prompt whose hook is already gone", function()
      -- The kill path leaves its prompts drawn after the turn dies, and they are still answerable
      -- as a new turn. Nothing is blocked on them, so holding would mean every later turn rendered
      -- nothing at all — the hold is keyed on hooks, not on lines.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()
      chat_buf:append_chunk("the next turn's output\n")

      vim.wait(300, function()
        return line_index(chat_buf, "the next turn's output") ~= nil
      end)
      assert.is_not_nil(line_index(chat_buf, "the next turn's output"), text(chat_buf))
    end)

    it("puts what arrived before the prompt above it", function()
      -- Held means "not yet", not "dropped": everything up to the moment the prompt is drawn
      -- belongs above it, in the assistant section the prompt interrupts.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:append_chunk("said before asking\n")
      chat_buf:show_approval_prompts()

      local said = line_index(chat_buf, "said before asking")
      local prompt = line_index(chat_buf, "Tool approval required")
      assert.is_not_nil(said, text(chat_buf))
      assert.is_true(said < prompt, "output from before the prompt must stay above it:\n" .. text(chat_buf))
    end)

    it("closes the assistant section the prompt interrupts", function()
      -- The end timestamp is what `cache_expiry` reads. Under the kill design it was written when
      -- the turn ended; a waiting turn does not end, so drawing the prompt is the moment.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      for _, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
        if line:match("^## Assistant") then
          assert.is_truthy(line:find("<!--", 1, true), "an interrupted section left unstamped: " .. line)
        end
      end
    end)

    it("flushes what it held into a new assistant section once the last prompt is answered", function()
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()
      chat_buf:append_chunk("arrived while waiting\n")

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))

      local held = line_index(chat_buf, "arrived while waiting")
      assert.is_not_nil(held, "the held output must reappear:\n" .. text(chat_buf))

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      local assistant
      for index = held, 1, -1 do
        if lines[index]:match("^## Assistant") then
          assistant = index
          break
        end
      end
      assert.is_not_nil(assistant, "it must land under an assistant header:\n" .. text(chat_buf))
      for index = assistant, #lines do
        assert.is_nil(lines[index]:match("^## User"), "no input section may sit above the output:\n" .. text(chat_buf))
      end
    end)

    it("stops calling itself waiting once the last prompt is answered", function()
      -- `_stop_reason` is cleared only where a new turn starts, and answering in place starts
      -- none. Left set, the chat reports `waiting_approval` from here until its next send —
      -- including after its turn has finished, with nothing left to answer. That is the
      -- "pretending to be responding" bug one layer over, in the other direction.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()
      assert.equals("waiting_approval", chat_buf:get_stop_reason())

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))

      assert.is_nil(chat_buf:get_stop_reason(), "the turn is running again; nothing is waiting")
    end)

    it("still calls itself waiting while another prompt is open", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      blocked_on(chat_buf, { "req-1", "req-2" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))

      assert.equals("waiting_approval", chat_buf:get_stop_reason())
    end)

    --- A turn stopped by us rather than answered: `:VibingCancel`, closing the chat, or simply
    --- typing a new message instead of answering (`send_message` cancels before it sends).
    --- @param chat_buf Vibing.ChatBuffer
    --- @param order string[]
    local function cancellable(chat_buf, order)
      chat_buf._current_process_id = "cancel-spec-process"
      chat_buf._get_active_adapter = function()
        return {
          stop_turn = function()
            table.insert(order, "stop")
          end,
        }
      end
    end

    it("releases the blocked hooks when the turn is cancelled instead of answered", function()
      local order = {}
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      cancellable(chat_buf, order)
      local original_resolve = Pending.resolve_for_chat
      ---@diagnostic disable-next-line: duplicate-set-field
      Pending.resolve_for_chat = function(bufnr, reason)
        table.insert(order, "release")
        return original_resolve(bufnr, reason)
      end

      local ok = pcall(function()
        chat_buf:cancel_request()
      end)
      Pending.resolve_for_chat = original_resolve
      assert.is_true(ok)

      assert.is_nil(Pending.get("req-1"), "a cancelled turn's hooks must not be left waiting")
      assert.same({ "release", "stop" }, order, "a stopped CLI can no longer stop waiting")
    end)

    it("lets the stream flow again after a cancel, rather than holding for a prompt nobody can answer", function()
      -- The prompts belong to the turn that was cancelled. Left in the list they hold the *next*
      -- turn's output too, and that turn would render nothing at all.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      cancellable(chat_buf, {})
      chat_buf:start_response()
      chat_buf:show_approval_prompts()
      chat_buf:append_chunk("the cancelled turn's tail\n")

      chat_buf:cancel_request()

      -- The drawn prompt stays: on the kill path it always has, and the user can still answer it
      -- as a new turn. What must not survive is the *hold*, and that is keyed on hooks actually
      -- blocked rather than on lines still on screen.
      assert.equals(1, #chat_buf:get_pending_approvals(), "the drawn prompt is not deleted")

      chat_buf:start_response()
      chat_buf:append_chunk("the next turn's output\n")
      vim.wait(300, function()
        return line_index(chat_buf, "the next turn's output") ~= nil
      end)
      assert.is_not_nil(line_index(chat_buf, "the next turn's output"), text(chat_buf))
      -- The held tail belonged to the turn that was cancelled. Flushed now it would be read as the
      -- opening of the turn the user started instead.
      assert.is_nil(line_index(chat_buf, "the cancelled turn's tail"), text(chat_buf))
    end)

    it("keeps holding while another prompt is still open", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      blocked_on(chat_buf, { "req-1", "req-2" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))
      chat_buf:append_chunk("still nowhere to put this\n")

      vim.wait(200)
      assert.is_nil(line_index(chat_buf, "still nowhere to put this"), text(chat_buf))
      assert.is_not_nil(line_index(chat_buf, "vibing:req=req-2"), "the unanswered prompt is redrawn")
    end)
  end)
end)
