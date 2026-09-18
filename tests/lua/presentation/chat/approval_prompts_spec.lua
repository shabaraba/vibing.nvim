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

    it("can still be answered after it expired, as a retry", function()
      -- The case this feature was first questioned on: "what if the user is away for half a day?"
      -- Under the kill design the prompt outlived the turn and answering it any time later retried
      -- the work. Waiting must not be worse than that past `approval_wait_sec` — expiry denies the
      -- one call that was in flight, it does not withdraw the user's chance to grant the
      -- permission.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:add_user_section()
      chat_buf:mark_approval_expired("req-1")

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      local header
      for index = #lines, 1, -1 do
        if lines[index]:match("^## User") then
          header = index
          break
        end
      end
      vim.api.nvim_buf_set_lines(chat_buf.buf, header, -1, false, {
        "",
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
      })

      local answered = chat_buf:_answer_pending_approval()

      assert.is_not_nil(answered)
      assert.equals("retry_as_new_turn", answered.outcome, vim.inspect(answered))
      assert.is_truthy(vim.tbl_contains(chat_buf:get_session_allow(), "Bash:once"))
    end)

    it("spends an expired prompt, because the grant is still the user's to give", function()
      -- Expiry denied the one call that was in flight. It did not decide that this permission may
      -- never be granted — recording the grant is exactly what lets the retry through.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:mark_approval_expired("req-1")

      local ApprovalDecision = require("vibing.application.chat.approval_decision")
      local consumed, err = ApprovalDecision.consume(chat_buf, { action = "allow_once", request_id = "req-1" })

      assert.is_not_nil(consumed, tostring(err))
      assert.is_truthy(vim.tbl_contains(chat_buf:get_session_allow(), "Bash:once"))
      assert.is_truthy(consumed.retry_message, "the answer has to be able to travel as a new turn")

      -- The ordinary retry message tells the model to proceed with the same operation, which is
      -- written for a turn that stopped *at* the prompt. After the limit the call was denied and
      -- the model carried on, so that instruction can redo work it already finished another way.
      assert.is_nil(
        consumed.retry_message:find("Please proceed with the same operation", 1, true),
        consumed.retry_message
      )
      assert.is_truthy(consumed.retry_message:find("unanswered", 1, true), consumed.retry_message)
    end)

    it("never sends an expired answer toward a hook", function()
      -- The half of the old refusal that was right, kept as its own case: the hook that asked is
      -- gone and its `.res` already carries a deny, so an answer must not be routed to it. That is
      -- structural rather than a check — expiry removed the registry entry — and this pins it.
      local Pending = require("vibing.infrastructure.rpc.pending_approvals")
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:add_user_section()
      chat_buf:mark_approval_expired("req-1")
      Pending._reset()

      local released = false
      local Permission = require("vibing.infrastructure.rpc.handlers.permission")
      local original = Permission.release_answered_approval
      ---@diagnostic disable-next-line: duplicate-set-field
      Permission.release_answered_approval = function(...)
        released = true
        return original(...)
      end

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      local header
      for index = #lines, 1, -1 do
        if lines[index]:match("^## User") then
          header = index
          break
        end
      end
      vim.api.nvim_buf_set_lines(chat_buf.buf, header, -1, false, {
        "",
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
      })

      local answered = chat_buf:_answer_pending_approval()
      Permission.release_answered_approval = original

      assert.equals("retry_as_new_turn", answered.outcome)
      assert.is_false(released, "there is no hook left to release")
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

    it("says an expired prompt expired, and keeps its options", function()
      -- Redrawing without the options would take away the only thing there is to answer, for the
      -- person most likely to need it: somebody back from a long absence, whose prompt expired
      -- while they were away. The mark says what changed — the answer now retries rather than
      -- releasing a hook — and the lines they act on stay.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:mark_approval_expired("req-1")

      local text = rendered(chat_buf)
      assert.is_truthy(text:find("expired", 1, true), text)
      assert.is_truthy(text:find("vibing:req=req-1", 1, true), "an expired prompt is still answerable: " .. text)
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
      local detail_lines = 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
        if line:find("not applied", 1, true) then
          count = count + 1
        end
        -- 見出しの下に続く `   理由` の行。見出しだけを消す実装だと、ここが押すたびに増える
        -- — 見出しは1本のままなので、上のカウントでは見えない積み上がりになる
        if line:find("^   %S") and line:find("req%-1") then
          detail_lines = detail_lines + 1
        end
      end
      assert.equals(1, count, "pressing <CR> twice must not leave two explanations")
      assert.equals(1, detail_lines, "and the explanation's continuation lines must not stack either")
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

    it("answers a prompt that already expired, as a new turn", function()
      -- End to end through `<CR>`: the grant is recorded and the send goes ahead, which is the
      -- kill path's behaviour and what makes waiting a superset of it at every point in time
      -- rather than only for the first `approval_wait_sec`.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:mark_approval_expired("req-1")

      type_and_send(chat_buf, {
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
      })

      assert.is_truthy(vim.tbl_contains(chat_buf:get_session_allow(), "Bash:once"))
      assert.is_nil(chat_buf:get_pending_approval("req-1"), "the prompt is spent, not left for a second answer")
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
    --- Asserted per id rather than as a total, so a case can block a second hook *after* the first
    --- prompt is already drawn — which is what parallel hooks actually do, and what the
    --- mid-turn redraw cases need. A total would have forced every registration into one call.
    local function blocked_on(chat_buf, request_ids)
      for _, request_id in ipairs(request_ids) do
        Pending.open({ request_id = request_id, chat_bufnr = chat_buf.buf, tool = "Bash" })
        local entry = Pending.get(request_id)
        assert.is_not_nil(entry, request_id .. " was not registered as blocked")
        assert.equals(chat_buf.buf, entry.chat_bufnr, request_id .. " is not filed under this chat")
      end
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
      chat_buf:show_pending_prompts()
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
      chat_buf:show_pending_prompts()
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
      chat_buf:show_pending_prompts()

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
      chat_buf:show_pending_prompts()

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
      chat_buf:show_pending_prompts()
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
      chat_buf:show_pending_prompts()
      assert.equals("waiting_approval", chat_buf:get_stop_reason())

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))

      assert.is_nil(chat_buf:get_stop_reason(), "the turn is running again; nothing is waiting")
    end)

    it("answers while the turn is still streaming, which is the only state it is ever asked in", function()
      -- **`_is_sending` is true for the whole of a running turn**, not just for the gap between
      -- `<CR>` and the CLI starting: `send_message` sets it and only `_handle_response` clears it.
      -- A prompt that holds a running turn open is therefore always answered in this state, and
      -- every other case here left the flag at its default — so the duplicate-send guard at the top
      -- of `send_message` was never exercised by a spec, and in the editor it swallowed the answer
      -- whole. Nothing is denied, nothing is retried: the hook simply spins to its own limit.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      chat_buf._is_sending = true

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))
      assert.equals(0, #Pending.list_for_chat(chat_buf.buf), "the hook must have been released")
    end)

    it("does not start a new turn when a streaming chat's <CR> answered nothing", function()
      -- The other half of the exemption. Opening the guard for an answer must not leave it open for
      -- everything else, or a stray `<CR>` cancels the turn the prompt is holding — which is the
      -- duplicate send the guard exists to stop.
      --
      -- **And it says so.** Typing a message instead of answering used to be one of the five ways a
      -- blocked hook was released; it is now four (`.claude/rules/permissions.md`), because this is
      -- the only one of them where the chat carries on afterwards. Dropping the message in silence
      -- would leave the user believing they had sent it — the same "quietly successful failure" the
      -- swallowed answer above was.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      chat_buf._is_sending = true

      local warned = {}
      local real_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(warned, { msg = msg, level = level })
      end
      local ok, sent = pcall(answer, chat_buf, { "never mind, do something else instead" })
      vim.notify = real_notify
      assert.is_true(ok, tostring(sent))

      assert.is_false(sent)
      assert.equals(1, #Pending.list_for_chat(chat_buf.buf), "the prompt is still answerable")
      assert.equals(1, #warned, "the user must be told the message was not sent")
      assert.is_truthy(warned[1].msg:find("VibingCancel", 1, true), warned[1].msg)
    end)

    it("says nothing about an empty <CR>, which was not a message", function()
      -- The other side of the same decision: a stray keypress needs no explanation, and warning on
      -- every one of them would train the user to ignore the warning that matters.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      chat_buf._is_sending = true

      local warned = {}
      local real_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(warned, { msg = msg, level = level })
      end
      local ok = pcall(answer, chat_buf, {})
      vim.notify = real_notify

      assert.is_true(ok)
      assert.equals(0, #warned)
      assert.equals(1, #Pending.list_for_chat(chat_buf.buf))
    end)

    it("still calls itself waiting while another prompt is open", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      blocked_on(chat_buf, { "req-1", "req-2" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()

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
      chat_buf:show_pending_prompts()
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

    it("releases them when the turn ends with hooks still blocked", function()
      -- A waiting hook keeps its turn open, so reaching the end with one still blocked means the
      -- CLI died first — a crash, a usage limit, an external kill. Those hooks have lost the only
      -- process that could read their answer. The wait limit would collect them 15 minutes later
      -- and tell the user they went unanswered for 900 seconds, which is not what happened.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      chat_buf:append_chunk("what the turn managed to say\n")

      chat_buf:_finish_turn()

      assert.is_nil(Pending.get("req-1"), "a finished turn's hooks have nobody left to answer them")
      -- The prompt was already drawn mid-turn. Closing the turn opens another input section and
      -- redraws whatever is pending into it, so without care the user is shown the same approval
      -- twice and only one of the two carries an answerable request.
      local _, drawn = text(chat_buf):gsub("Tool approval required", "")
      assert.equals(1, drawn, "the prompt must not be drawn a second time:\n" .. text(chat_buf))
      -- Unlike a cancel, the held tail belongs to *this* turn and the section closing right here is
      -- where it goes.
      assert.is_not_nil(line_index(chat_buf, "what the turn managed to say"), text(chat_buf))
    end)

    it("keeps what the user typed while the turn was running", function()
      -- The de-duplication above recycles the trailing unsent section before redrawing. The same
      -- section is where the user types, and a turn ending is not a reason to delete their message.
      --
      -- **A prompt has to be drawn for this to test anything.** Written first with `chat_with({})`,
      -- it never set `_approvals_rendered_unsent`, so `_finish_turn` skipped the branch the case is
      -- named after and passed while the branch deleted the line.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()
      assert.is_true(chat_buf._approvals_rendered_unsent, "the branch under test was not reached")

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(chat_buf.buf, #lines, #lines, false, { "half-written question" })

      chat_buf:_finish_turn()

      assert.is_not_nil(line_index(chat_buf, "half-written question"), text(chat_buf))
      -- And the prompt still comes back exactly once, which is what the section was recycled for.
      local _, drawn = text(chat_buf):gsub("Tool approval required", "")
      assert.equals(1, drawn, text(chat_buf))
    end)

    it("keeps what the user typed when a second prompt arrives mid-turn", function()
      -- The other caller of the same recycling. Hooks run in parallel, so a prompt can land while
      -- the user is part-way through typing under the first one.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(chat_buf.buf, #lines, #lines, false, { "half-written question" })

      chat_buf:insert_approval_request("Write", { file_path = "/tmp/x" }, {
        { value = "allow_once", label = "allow_once - Allow this execution only" },
      }, "req-2", true)
      blocked_on(chat_buf, { "req-2" })
      chat_buf:show_approval_prompts()

      assert.is_not_nil(line_index(chat_buf, "half-written question"), text(chat_buf))
    end)

    it("draws a second prompt into the section that is already open, not a new one", function()
      -- `add_user_section` renders **every** pending prompt, so calling it once per arriving hook
      -- stacks unsent `## User` sections *and* redraws the earlier prompts inside each new one:
      -- with three hooks, req-1's option lines appear three times, carrying the same marker, and
      -- only the last copy is the one `extract_user_message` will read. Measured on claude as three
      -- hooks 0.54s apart, so this is the ordinary case rather than a corner.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      chat_buf:insert_approval_request("Write", { file_path = "/tmp/x" }, {
        { value = "allow_once", label = "allow_once - Allow this execution only" },
        { value = "deny_once", label = "deny_once - Deny this execution only" },
      }, "req-2", true)
      blocked_on(chat_buf, { "req-2" })
      chat_buf:show_approval_prompts()

      local body = text(chat_buf)
      local _, blocks = body:gsub("Tool approval required", "")
      assert.equals(2, blocks, "one block per pending prompt, drawn once each:\n" .. body)

      -- Counted per prompt, not in total: the duplicate is what makes an answer unattributable, and
      -- a total would also be satisfied by two prompts sharing one block.
      for _, request_id in ipairs({ "req%-1", "req%-2" }) do
        local _, marked = body:gsub("vibing:req=" .. request_id, "")
        assert.equals(2, marked, request_id .. " is not drawn exactly once (2 option lines):\n" .. body)
      end

      -- One input section. `view.render` leaves an empty one behind that these cases never send
      -- through, so the prompts add exactly one more.
      local _, headers = body:gsub("## User", "")
      assert.equals(2, headers, "the prompts opened more than one input section:\n" .. body)
    end)

    it("says in the buffer that the output is paused, so waiting is not mistaken for hanging", function()
      -- A prompt with nothing moving under it looks exactly like a frozen editor, and on the
      -- waiting path that lasts up to `approval_wait_sec`.
      local chat_buf = chat_with({})
      chat_buf:insert_approval_request("Bash", {}, {
        { value = "allow_once", label = "allow_once - Allow this execution only" },
      }, "req-1", true)
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()

      assert.is_not_nil(line_index(chat_buf, "output is paused"), text(chat_buf))
    end)

    it("does not claim anything is paused on the kill path", function()
      -- There the process is already dead and nothing is being held, so the line would be a lie.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      chat_buf:add_user_section()

      assert.is_nil(line_index(chat_buf, "output is paused"), text(chat_buf))
    end)

    it("flushes what it held when the prompt expires instead of being answered", function()
      -- The exit that is easiest to forget: nobody answered, so none of the answering code runs,
      -- and a buffering layer whose exit is missing loses the output in silence.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      Pending.open({
        request_id = "req-1",
        chat_bufnr = chat_buf.buf,
        tool = "Bash",
        on_timeout = require("vibing.infrastructure.rpc.handlers.permission")._on_approval_expired,
      })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      chat_buf:append_chunk("held until the limit\n")

      assert.is_true(Pending.expire("req-1"))

      assert.is_not_nil(line_index(chat_buf, "held until the limit"), text(chat_buf))
      assert.is_not_nil(line_index(chat_buf, "Tool approval expired"), text(chat_buf))
    end)

    it("puts the flushed output where the next send will not read it back", function()
      -- "It appeared in the buffer" is not enough: appearing under the input section is the whole
      -- bug. `extract_user_message` finds the last user-role header and reads to the next one —
      -- and it does **not** check whether that header is unsent (`extract_role` answers "user" for
      -- every Kind except Assistant), so a committed section is just as readable.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      chat_buf:append_chunk("model output, not a user message\n")

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))

      assert.is_not_nil(line_index(chat_buf, "model output, not a user message"), text(chat_buf))
      local extracted = chat_buf:extract_user_message() or ""
      assert.is_nil(
        extracted:find("model output, not a user message", 1, true),
        "the flushed output must not be readable as the user's next message: " .. extracted
      )
    end)

    it("leaves a transcript that reads in the order it happened", function()
      -- The shape everything in this describe adds up to, asserted once end to end. Each piece has
      -- its own case above; what this pins is that they compose — a turn interrupted by an approval
      -- and then resumed must not read as two turns, as a turn that answered itself, or as output
      -- filed under the user.
      local chat_buf = chat_with({ { tool = "Bash", request_id = "req-1" } })
      blocked_on(chat_buf, { "req-1" })
      chat_buf:start_response()
      chat_buf:append_chunk("before asking\n")
      chat_buf:show_pending_prompts()
      chat_buf:append_chunk("while waiting\n")
      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))
      chat_buf:append_chunk("after answering\n")
      chat_buf:_finish_turn()

      local shape = {}
      for _, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
        if line:match("^## Assistant") then
          table.insert(shape, "assistant")
        elseif line:match("^## User") then
          table.insert(shape, line:find("unsent", 1, true) and "input" or "user")
        elseif
          line:find("before asking", 1, true)
          or line:find("while waiting", 1, true)
          or line:find("after answering", 1, true)
        then
          table.insert(shape, line)
        elseif line:find("vibing:req=req-1", 1, true) then
          table.insert(shape, "answer")
        end
      end

      assert.same({
        -- The empty input section `view.render` leaves behind; this test never sends through it.
        "input",
        "assistant",
        "before asking",
        -- The prompt's own lines are gone because answering is `dd` plus `<CR>`: what stays in the
        -- transcript is the option line the user kept, in a section stamped as sent.
        "user",
        "answer",
        "assistant",
        "while waiting",
        "after answering",
        "input",
      }, shape, text(chat_buf))
    end)

    it("keeps holding while another prompt is still open", function()
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      blocked_on(chat_buf, { "req-1", "req-2" })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()

      assert.is_true(answer(chat_buf, { "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->" }))
      chat_buf:append_chunk("still nowhere to put this\n")

      vim.wait(200)
      assert.is_nil(line_index(chat_buf, "still nowhere to put this"), text(chat_buf))
      assert.is_not_nil(line_index(chat_buf, "vibing:req=req-2"), "the unanswered prompt is redrawn")

      -- What the orphaned-prompt case costs, stated as a test rather than as a hope. copilot
      -- re-runs a hook it cut under a **new** request id, so one tool call can leave a prompt
      -- nothing will ever answer; its registry entry outlives every answer the user gives. The
      -- turn's remaining output is then held until the turn itself ends — late, but not lost.
      chat_buf:_finish_turn()
      assert.is_not_nil(line_index(chat_buf, "still nowhere to put this"), text(chat_buf))
    end)

    it("answers every prompt the user left a line for, not just the first", function()
      -- `ApprovalParser.resolve` returns one answer per prompt and reports no error when the user
      -- kept exactly one line from each — which is the natural way to clear two prompts at once.
      -- Consuming only `resolved[1]` dropped the rest **silently**: the second hook stayed blocked
      -- with its answer already typed into the transcript, and the wait limit denied it 900s later.
      -- An `allow_once` answered that way ends in the opposite of what the user chose.
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      blocked_on(chat_buf, { "req-1", "req-2" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      assert.is_true(answer(chat_buf, {
        "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
        "2. deny_once - Deny this execution only <!-- vibing:req=req-2 -->",
      }))

      -- The registry is the fact: an entry still there is a CLI still sitting inside its hook.
      assert.is_nil(Pending.get("req-1"), "req-1 was left blocked:\n" .. text(chat_buf))
      assert.is_nil(Pending.get("req-2"), "req-2's answer was dropped:\n" .. text(chat_buf))
      assert.equals(0, #chat_buf:get_pending_approvals(), "a prompt outlived its answer")
    end)

    it("leaves only the answer it could not apply, and says which", function()
      -- Neither extreme is right. Rolling every answer back reads as "I answered and it vanished";
      -- carrying on in silence hides the one that did not land. So the failed prompt stays
      -- answerable and the rest are spent — and the reason is said out loud, because on screen the
      -- only symptom is a prompt that did not go away.
      local chat_buf = chat_with({
        { tool = "Bash", request_id = "req-1" },
        { tool = "Write", request_id = "req-2" },
      })
      blocked_on(chat_buf, { "req-1", "req-2" })
      chat_buf:start_response()
      chat_buf:show_approval_prompts()

      local ApprovalDecision = require("vibing.application.chat.approval_decision")
      local original = ApprovalDecision.consume
      ---@diagnostic disable-next-line: duplicate-set-field
      ApprovalDecision.consume = function(buf, approval)
        if approval.request_id == "req-1" then
          return nil, "permissions were not writable"
        end
        return original(buf, approval)
      end
      local ok, err = pcall(function()
        answer(chat_buf, {
          "1. allow_once - Allow this execution only <!-- vibing:req=req-1 -->",
          "2. deny_once - Deny this execution only <!-- vibing:req=req-2 -->",
        })
      end)
      ApprovalDecision.consume = original
      assert.is_true(ok, tostring(err))

      assert.is_not_nil(Pending.get("req-1"), "the failed answer must leave its hook answerable")
      assert.is_nil(Pending.get("req-2"), "the answer that succeeded must still be spent")

      local body = text(chat_buf)
      assert.is_truthy(body:find("req-1", 1, true), "the failure does not name the request:\n" .. body)
      assert.is_truthy(
        body:find("permissions were not writable", 1, true),
        "the failure does not say why:\n" .. body
      )
    end)
  end)
end)
