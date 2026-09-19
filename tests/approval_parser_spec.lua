-- Tests for approval_parser module

describe("vibing.presentation.chat.modules.approval_parser", function()
  local ApprovalParser

  before_each(function()
    package.loaded["vibing.presentation.chat.modules.approval_parser"] = nil
    ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
  end)

  describe("is_approval_response", function()
    it("should return true for allow_once pattern", function()
      local message = "1. allow_once - Allow this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true for deny_once pattern", function()
      local message = "2. deny_once - Deny this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true for allow_for_session pattern", function()
      local message = "3. allow_for_session - Allow for this session"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true for deny_for_session pattern", function()
      local message = "4. deny_for_session - Deny for this session"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true with leading spaces", function()
      local message = "  1. allow_once - Allow this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true with quote marker", function()
      local message = "> 1. allow_once - Allow this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return false for non-approval message", function()
      local message = "Please run the tests"
      assert.is_false(ApprovalParser.is_approval_response(message))
    end)

    it("should return false for empty string", function()
      assert.is_false(ApprovalParser.is_approval_response(""))
    end)

    it("should return false for nil", function()
      assert.is_false(ApprovalParser.is_approval_response(nil))
    end)

    it("should return false for non-string", function()
      assert.is_false(ApprovalParser.is_approval_response(123))
    end)
  end)

  describe("option_line", function()
    it("is the only place a prompt line is composed, marker included", function()
      -- The number is the option's position inside one prompt's list, so with several prompts up
      -- at once the same "1. allow_once - ..." appears more than once. The marker is what makes an
      -- answer attributable.
      local line = ApprovalParser.option_line(2, "deny_once - Deny this execution only", "req-abc")
      assert.equals("2. deny_once - Deny this execution only <!-- vibing:req=req-abc -->", line)
    end)

    it("still reads as an approval response, so the marker cannot break the old pattern", function()
      local line = ApprovalParser.option_line(1, "allow_once - Allow this execution only", "req-abc")
      assert.is_true(ApprovalParser.is_approval_response(line))
      assert.same({ { action = "allow_once", request_id = "req-abc" } }, ApprovalParser.parse_answers(line))
    end)

    it("omits the marker when there is no request to name", function()
      assert.equals("1. allow_once - x", ApprovalParser.option_line(1, "allow_once - x"))
    end)
  end)

  describe("parse_answers", function()
    it("reads every option line, not just the first", function()
      -- "first match wins" is what let a forgotten line answer a different prompt. What is written
      -- is reported; deciding what it means is `resolve`.
      local message = table.concat({
        "1. allow_once - Allow <!-- vibing:req=a -->",
        "2. deny_once - Deny <!-- vibing:req=b -->",
      }, "\n")
      assert.same({
        { action = "allow_once", request_id = "a" },
        { action = "deny_once", request_id = "b" },
      }, ApprovalParser.parse_answers(message))
    end)

    it("reads a line with no marker as unattributed rather than skipping it", function()
      assert.same({ { action = "deny_for_session" } }, ApprovalParser.parse_answers("4. deny_for_session - x"))
    end)

    it("tolerates quoting and leading whitespace, as the buffer may contain either", function()
      local answers = ApprovalParser.parse_answers("> 1. allow_once - x <!-- vibing:req=a -->")
      assert.same({ { action = "allow_once", request_id = "a" } }, answers)
    end)

    it("returns nothing for prose", function()
      assert.same({}, ApprovalParser.parse_answers("just a normal message"))
      assert.same({}, ApprovalParser.parse_answers(""))
      assert.same({}, ApprovalParser.parse_answers(nil))
    end)
  end)

  describe("resolve", function()
    it("takes the one line left for a request", function()
      local answers, errors = ApprovalParser.resolve("1. allow_once - x <!-- vibing:req=a -->", { "a" })
      assert.same({}, errors)
      assert.same({ { request_id = "a", action = "allow_once" } }, answers)
    end)

    it("answers several prompts in one send", function()
      local message = table.concat({
        "1. allow_once - x <!-- vibing:req=a -->",
        "2. deny_once - y <!-- vibing:req=b -->",
      }, "\n")
      local answers, errors = ApprovalParser.resolve(message, { "a", "b" })
      assert.same({}, errors)
      assert.equals(2, #answers)
    end)

    it("leaves an unanswered prompt alone instead of failing the whole send", function()
      local answers, errors = ApprovalParser.resolve("1. allow_once - x <!-- vibing:req=a -->", { "a", "b" })
      assert.same({}, errors)
      assert.same({ { request_id = "a", action = "allow_once" } }, answers)
    end)

    it("refuses two lines left for the same request", function()
      -- The footgun this rule removes: pressing <CR> without deleting anything used to take the
      -- first line, which is always `allow_once`. Doing nothing must not produce a grant.
      local message = table.concat({
        "1. allow_once - x <!-- vibing:req=a -->",
        "2. deny_once - y <!-- vibing:req=a -->",
      }, "\n")
      local answers, errors = ApprovalParser.resolve(message, { "a" })
      assert.same({}, answers, "nothing may be consumed when the answer is ambiguous")
      assert.equals(1, #errors)
      assert.is_truthy(errors[1]:find("a", 1, true), errors[1])
    end)

    it("takes an unmarked line only while exactly one approval is waiting", function()
      local answers, errors = ApprovalParser.resolve("1. allow_once - x", { "a" })
      assert.same({}, errors)
      assert.same({ { request_id = "a", action = "allow_once" } }, answers)
    end)

    it("refuses an unmarked line while several are waiting", function()
      local answers, errors = ApprovalParser.resolve("1. allow_once - x", { "a", "b" })
      assert.same({}, answers)
      assert.equals(1, #errors)
      assert.is_truthy(errors[1]:find("vibing:req", 1, true), "the message must say how to fix it")
    end)

    it("refuses a marked and an unmarked line for the same request", function()
      local message = table.concat({ "1. allow_once - x <!-- vibing:req=a -->", "2. deny_once - y" }, "\n")
      local answers, errors = ApprovalParser.resolve(message, { "a" })
      assert.same({}, answers)
      assert.equals(1, #errors)
    end)

    it("refuses an answer to a request that is no longer waiting", function()
      -- Answering a prompt that expired while the user was reading. Dropping it silently reads as
      -- "I chose and nothing happened".
      local answers, errors = ApprovalParser.resolve("1. allow_once - x <!-- vibing:req=gone -->", { "a" })
      assert.same({}, answers)
      assert.equals(1, #errors)
      assert.is_truthy(errors[1]:find("gone", 1, true), errors[1])
    end)

    it("consumes nothing at all when any part is ambiguous", function()
      -- Applying the good half and reporting the rest would leave the user unable to tell from the
      -- buffer how far the send got.
      local message = table.concat({
        "1. allow_once - x <!-- vibing:req=a -->",
        "1. allow_once - y <!-- vibing:req=b -->",
        "2. deny_once - y <!-- vibing:req=b -->",
      }, "\n")
      local answers, errors = ApprovalParser.resolve(message, { "a", "b" })
      assert.same({}, answers)
      assert.equals(1, #errors)
    end)

    it("returns nothing for a message with no option lines", function()
      local answers, errors = ApprovalParser.resolve("never mind", { "a" })
      assert.same({}, answers)
      assert.same({}, errors)
    end)
  end)

  -- `generate_response_message` の describe はここにあった。本番コードからの参照が無い関数を、
  -- この spec だけが緑に保っていた — しかも中身は `approval_decision.retry_message` とは別の
  -- 文面の、承認の意味の2つ目の実装。#778 で関数ごと消した。

  describe("strip_prompt_lines", function()
    --- Exactly what the renderer writes, so a change to the block's shape breaks this rather than
    --- quietly leaving lines behind in the buffer it is used to clean.
    local function rendered(request_id)
      return {
        ApprovalParser.PROMPT_HEADER,
        "",
        "Tool: Bash",
        "Command: npm install",
        "",
        ApprovalParser.option_line(1, "allow_once - Allow this execution only", request_id),
        ApprovalParser.option_line(2, "deny_once - Deny this execution only", request_id),
        "   (the rest of this turn's output is paused until this is answered)",
        "",
      }
    end

    it("removes a whole rendered block, instruction line included", function()
      local lines = rendered("req-1")
      table.insert(lines, ApprovalParser.INSTRUCTION_LINE)
      table.insert(lines, "")

      local kept, removed = ApprovalParser.strip_prompt_lines(lines)

      assert.same({}, kept, "left behind: " .. table.concat(kept, " | "))
      assert.equals(#lines, removed)
    end)

    it("keeps what the user typed under the prompt", function()
      -- The whole reason this exists. The user types into the same unsent section the prompt was
      -- drawn into, and the section used to be dropped entire.
      local lines = rendered("req-1")
      table.insert(lines, ApprovalParser.INSTRUCTION_LINE)
      table.insert(lines, "")
      table.insert(lines, "half-written question")
      table.insert(lines, "and a second line")

      local kept = ApprovalParser.strip_prompt_lines(lines)

      assert.same({ "half-written question", "and a second line" }, kept)
    end)

    it("keeps user text written above the prompt too", function()
      local lines = { "typed before the hook landed", "" }
      vim.list_extend(lines, rendered("req-1"))
      table.insert(lines, ApprovalParser.INSTRUCTION_LINE)

      local kept = ApprovalParser.strip_prompt_lines(lines)

      -- The separating blank is the user's line too; `_recycle_prompt_section` trims the edges
      -- before carrying the text over, so it is not this function's job to guess.
      assert.same({ "typed before the hook landed", "" }, kept)
    end)

    it("does not treat an indented line of the user's own as part of a block", function()
      -- `   ` continues a block, because the paused/expired/refusal notes are indented. It must not
      -- *open* one: a user pasting indented code would lose it.
      local kept = ApprovalParser.strip_prompt_lines({ "   indented note", "plain note" })

      assert.same({ "   indented note", "plain note" }, kept)
    end)

    it("removes the expiry and refusal notes the block accumulates", function()
      -- Written by `expire_approval` and `_show_approval_refusal` rather than by the renderer, and
      -- appended after the block. Left behind, they are redrawn under the next copy of the prompt
      -- and read back as the user's next message.
      local kept = ApprovalParser.strip_prompt_lines({
        ApprovalParser.EXPIRED_NOTICE_PREFIX .. " Bash went unanswered for 900 seconds.",
        "   The options for it above no longer need an answer.",
        ApprovalParser.REFUSAL_PREFIX,
        "   Request req-9 is no longer waiting for an answer.",
        "still mine",
      })

      assert.same({ "still mine" }, kept)
    end)

    it("stops at the end of the block when the instruction line was deleted", function()
      -- Answering is `dd` plus `<CR>`, so any line of the block can be gone by the time this runs.
      -- Without the instruction line the block has to end where its furniture ends, not run on
      -- into whatever the user wrote next.
      local lines = rendered("req-1")
      table.insert(lines, "my own words")

      local kept = ApprovalParser.strip_prompt_lines(lines)

      assert.same({ "my own words" }, kept)
    end)

    it("leaves a section with no prompt in it completely alone", function()
      local lines = { "just a message", "", "over two paragraphs" }

      local kept, removed = ApprovalParser.strip_prompt_lines(lines)

      assert.same(lines, kept)
      assert.equals(0, removed)
    end)
  end)
end)
