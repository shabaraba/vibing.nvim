---@diagnostic disable: undefined-field
--- Answering a CLI's **own** approval request, in the chat the hook's prompts are drawn in (#861).
---
--- The two kinds share the block, the marker and the `<CR>`; what they must not share is what the
--- answer *means*. A hook approval is a statement about vibing's permissions and spends one; a
--- Codex approval is a statement about Codex's sandbox and spends none. These specs pin that
--- separation from the chat's side, where both prompts can be on screen at once.
local ChatBuffers = require("tests.helpers.chat_buffers")
local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
local Decisions = require("vibing.infrastructure.adapter.modules.codex_native_decisions")
local Native = require("vibing.infrastructure.rpc.pending_native_approvals")

describe("answering a Codex approval in the chat", function()
  local view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
  end)

  after_each(function()
    Native._reset()
    ChatBuffers.reset()
  end)

  local HOOK_OPTIONS = {
    { value = "allow_once", label = "allow_once - Allow this execution only" },
    { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
    { value = "deny_once", label = "deny_once - Deny this execution only" },
  }

  --- A chat holding one native prompt whose request is really waiting for a decision.
  --- @return Vibing.ChatBuffer, table decisions written back to the CLI
  local function chat_with_native(available, request_id)
    request_id = request_id or "codex-p1-0"
    local chat_buf = view.render({ session_id = "codex-approvals" }, "back")
    local options = Decisions.options(available)
    chat_buf:insert_approval_request(
      "Codex command execution",
      { command = "/bin/zsh -lc 'ls'" },
      options,
      request_id,
      true,
      "native"
    )

    local decisions = {}
    Native.open({
      request_id = request_id,
      chat_bufnr = chat_buf.buf,
      tool = "Codex command execution",
      respond = function(decision)
        table.insert(decisions, decision)
      end,
    })
    return chat_buf, decisions, options
  end

  --- Put `answer_lines` under the last user header and press `<CR>`.
  local function answer(chat_buf, answer_lines)
    local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
    local header
    for index = #lines, 1, -1 do
      if lines[index]:match("^## User") then
        header = index
        break
      end
    end
    assert.is_not_nil(header, "the prompt should already be drawn")

    local kept = { "" }
    vim.list_extend(kept, answer_lines)
    vim.api.nvim_buf_set_lines(chat_buf.buf, header, -1, false, kept)
    return chat_buf:_answer_pending_approval()
  end

  local function line_for(options, value, request_id)
    for index, option in ipairs(options) do
      if option.value == value then
        return ApprovalParser.option_line(index, option.label, request_id)
      end
    end
    error("no option named " .. value)
  end

  describe("what the answer does not do", function()
    it("never writes to this chat's session allow/deny lists", function()
      -- The whole point of the separate channel. Codex asked whether a call may leave *its*
      -- sandbox; the human saying yes has said nothing about vibing's `permissions.allow`.
      local chat_buf, _, options = chat_with_native({ "accept", "cancel" })
      chat_buf:show_pending_prompts()

      local outcome = answer(chat_buf, { line_for(options, "accept", "codex-p1-0") })

      assert.equals("answered_in_place", outcome.outcome)
      assert.same({}, chat_buf:get_session_allow())
      assert.same({}, chat_buf:get_session_deny())
    end)

    it("the hook's own prompt still does, which is what makes the case above a difference", function()
      -- The positive control. Without it, "the lists stayed empty" would be green for a chat that
      -- simply never records anything.
      local chat_buf = view.render({ session_id = "hook-approvals" }, "back")
      chat_buf:insert_approval_request("Bash", { command = "ls" }, HOOK_OPTIONS, "req-1")
      chat_buf:show_pending_prompts()

      answer(chat_buf, { ApprovalParser.option_line(2, HOOK_OPTIONS[2].label, "req-1") })

      assert.same({ "Bash" }, chat_buf:get_session_allow())
    end)
  end)

  describe("what the answer does", function()
    it("sends the decision the human picked back to the CLI", function()
      local chat_buf, decisions, options = chat_with_native({ "accept", "cancel" })
      chat_buf:show_pending_prompts()

      answer(chat_buf, { line_for(options, "accept", "codex-p1-0") })

      assert.same({ "accept" }, decisions)
    end)

    it("sends an object decision with its body intact", function()
      local amendment = { acceptWithExecpolicyAmendment = { execpolicy_amendment = { "/bin/zsh", "-lc", "ls" } } }
      local chat_buf, decisions, options = chat_with_native({ "accept", amendment })
      chat_buf:show_pending_prompts()

      answer(chat_buf, { line_for(options, "accept_with_execpolicy_amendment", "codex-p1-0") })

      assert.same({ amendment }, decisions)
    end)

    it("refuses the call without ending the turn when the human declines", function()
      local chat_buf, decisions, options = chat_with_native({ "accept", "cancel" })
      chat_buf:show_pending_prompts()

      answer(chat_buf, { line_for(options, "decline", "codex-p1-0") })

      assert.same({ "decline" }, decisions)
    end)

    it("drops the prompt, so a second <CR> cannot answer it twice", function()
      local chat_buf, decisions, options = chat_with_native({ "accept" })
      chat_buf:show_pending_prompts()

      answer(chat_buf, { line_for(options, "accept", "codex-p1-0") })
      assert.equals(0, #chat_buf:get_pending_approvals())
      assert.same({ "accept" }, decisions)
    end)
  end)

  describe("two vocabularies on one screen", function()
    it("reads a Codex option line that the hook's four words cannot match", function()
      -- Before the vocabulary travelled with the prompt, this line was ordinary prose: it matched
      -- nothing, so the answer reached nobody and the request waited out its limit.
      local chat_buf, _, options = chat_with_native({ "accept", "cancel" })

      local line = line_for(options, "accept", "codex-p1-0")
      assert.is_false(ApprovalParser.is_approval_response(line))
      assert.is_true(ApprovalParser.is_approval_response(line, chat_buf:_approval_vocabulary()))
    end)

    it("answers each prompt in its own vocabulary when both are waiting", function()
      local chat_buf, decisions, options = chat_with_native({ "accept", "cancel" })
      chat_buf:insert_approval_request("Bash", { command = "ls" }, HOOK_OPTIONS, "req-1")
      chat_buf:show_pending_prompts()

      answer(chat_buf, {
        line_for(options, "accept", "codex-p1-0"),
        ApprovalParser.option_line(2, HOOK_OPTIONS[2].label, "req-1"),
      })

      -- The Codex one reached the CLI; the hook one reached the permission lists. Neither reached
      -- the other's channel.
      assert.same({ "accept" }, decisions)
      assert.same({ "Bash" }, chat_buf:get_session_allow())
    end)
  end)

  describe("a decision whose name is not a plain word", function()
    it("is read back literally, not as the Lua pattern its characters spell", function()
      -- The vocabulary is the CLI's to choose (#861), so what reaches `action_pattern` is a word
      -- vibing did not pick. `codex_native_decisions.slug` folds today's names to `[a-z0-9_]`, but
      -- that is a *producer* keeping a promise for a consumer two modules away — and the consumer
      -- is building a **Lua pattern**. Unescaped, `accept-%d` matches "accept-" followed by a
      -- digit: the human's actual line matches nothing, the answer is discarded in silence, and
      -- the request waits out its whole limit. So the escaping lives where the pattern is built.
      local vocabulary = { "accept-%d" }
      local line = ApprovalParser.option_line(1, "accept-%d - Run it", "codex-p1-0")

      assert.is_true(ApprovalParser.is_approval_response(line, vocabulary))
      assert.same(
        { { action = "accept-%d", request_id = "codex-p1-0" } },
        ApprovalParser.parse_answers(line, vocabulary)
      )

      -- The pattern must not match what it would have matched read as a pattern.
      assert.is_false(
        ApprovalParser.is_approval_response(
          ApprovalParser.option_line(1, "accept-7 - Run it", "codex-p1-0"),
          vocabulary
        )
      )
    end)
  end)

  describe("a decision this prompt did not offer", function()
    it("is refused rather than sent, and the request stays waiting", function()
      local chat_buf, decisions = chat_with_native({ "accept" })
      chat_buf:show_pending_prompts()

      -- `cancel` is a real Codex decision, just not one this request offered.
      answer(chat_buf, { ApprovalParser.option_line(1, "cancel - Abort the turn", "codex-p1-0") })

      assert.same({}, decisions)
      assert.is_not_nil(Native.get("codex-p1-0"))
    end)
  end)
end)
