---@diagnostic disable: undefined-field
--- What `availableDecisions` becomes in the chat (#861).
---
--- Every shape asserted here was taken off a real `codex app-server` run (codex-cli 0.160.1), not
--- read off the docs: the array mixes strings with single-key objects, `item/fileChange/
--- requestApproval` carries no `availableDecisions` key at all, and `decline` was offered by none of
--- them while being honoured by all of them.
local Decisions = require("vibing.infrastructure.adapter.modules.codex_native_decisions")

describe("codex native decisions", function()
  --- @return table<string, Vibing.CodexDecisionOption>
  local function by_value(options)
    local map = {}
    for _, option in ipairs(options) do
      map[option.value] = option
    end
    return map
  end

  local function values(options)
    return vim.tbl_map(function(option)
      return option.value
    end, options)
  end

  describe("the measured shape", function()
    it("reads the mixed string/object array one command approval actually sent", function()
      local amendment = { acceptWithExecpolicyAmendment = { execpolicy_amendment = { "/bin/zsh", "-lc", "ls" } } }

      local options = Decisions.options({ "accept", amendment, "cancel" })

      assert.same({ "accept", "accept_with_execpolicy_amendment", "cancel", "decline" }, values(options))
    end)

    it("echoes an object decision back exactly as it arrived", function()
      -- Rebuilding the body from the slug would be a second copy of codex's schema, and the
      -- amendment bodies are the part most likely to gain a field.
      local amendment = { acceptWithExecpolicyAmendment = { execpolicy_amendment = { "/bin/zsh", "-lc", "ls" } } }

      local chosen = by_value(Decisions.options({ amendment })).accept_with_execpolicy_amendment

      assert.same(amendment, chosen.raw)
    end)

    it("keeps a plain string decision as a plain string", function()
      assert.equals("accept", by_value(Decisions.options({ "accept" })).accept.raw)
    end)
  end)

  describe("decline is always offered", function()
    it("appends it when codex listed it nowhere", function()
      -- Measured: replying `{decision="decline"}` marks that one call `declined`, the model is
      -- told, and the turn completes normally — even though no observed request listed it.
      local options = by_value(Decisions.options({ "accept", "cancel" }))

      assert.is_not_nil(options.decline)
      assert.equals("decline", options.decline.raw)
      assert.is_false(options.decline.is_allow)
    end)

    it("does not offer it twice when codex did list it", function()
      local offered = values(Decisions.options({ "accept", "decline" }))

      assert.same({ "accept", "decline" }, offered)
    end)

    it("sits below whatever codex offered", function()
      local offered = values(Decisions.options({ "accept", "cancel" }))

      assert.equals("decline", offered[#offered])
    end)
  end)

  describe("a request that offers nothing", function()
    it("still gets a usable pair, which is what fileChange needs", function()
      -- `item/fileChange/requestApproval`'s params carry no `availableDecisions` key.
      assert.same({ "accept", "decline" }, values(Decisions.options(nil)))
      assert.same({ "accept", "decline" }, values(Decisions.options({})))
    end)
  end)

  describe("what a decision means", function()
    it("treats every accept variant as letting the call run", function()
      assert.is_true(Decisions.is_allow("accept"))
      assert.is_true(Decisions.is_allow("accept_for_session"))
      assert.is_true(Decisions.is_allow("accept_with_execpolicy_amendment"))
    end)

    it("treats everything else as refusing it", function()
      -- The safe direction for each: a new `accept…` is allowed, a new refusal refuses.
      assert.is_false(Decisions.is_allow("decline"))
      assert.is_false(Decisions.is_allow("cancel"))
      assert.is_false(Decisions.is_allow("something_codex_added_later"))
    end)

    it("refuses with decline, which is the one the three unanswered exits write", function()
      assert.equals("decline", Decisions.refusal())
    end)
  end)

  describe("the value is safe to interpolate into a Lua pattern", function()
    it("folds everything outside [a-z0-9] into underscores", function()
      -- `approval_parser.action_pattern` puts this straight into a Lua pattern, where a `-` is a
      -- quantifier and a `%` escapes. A decision nobody has seen yet must not be able to break it.
      assert.equals("accept_with_prefix", Decisions.slug("accept-with-prefix"))
      assert.equals("accept_100", Decisions.slug("accept.100%"))
      assert.equals("accept_with_execpolicy_amendment", Decisions.slug("acceptWithExecpolicyAmendment"))
    end)

    it("produces a label the option-line grammar can read back", function()
      local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
      local options = Decisions.options({ "accept", "cancel" })
      local vocabulary = values(options)

      local line = ApprovalParser.option_line(1, options[1].label, "codex-p1-0")
      local answers = ApprovalParser.parse_answers(line, vocabulary)

      assert.same({ { action = "accept", request_id = "codex-p1-0" } }, answers)
    end)
  end)
end)
