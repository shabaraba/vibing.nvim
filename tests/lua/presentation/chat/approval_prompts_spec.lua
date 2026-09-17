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
end)
