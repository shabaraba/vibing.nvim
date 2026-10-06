---@diagnostic disable: undefined-field
--- A Codex app-server approval request waits for a human instead of being refused on arrival
--- (#861).
---
--- The contract is both siblings': every withheld response is eventually written, exactly once.
--- What these specs pin is the part that is *not* shared — the response is a JSON-RPC result rather
--- than a `.res` file or an MCP tool result, reaching the wait limit **declines without ending the
--- turn**, and there is a fifth exit the other two have no equivalent of: codex resolving its own
--- request.
local PendingNative = require("vibing.infrastructure.rpc.pending_native_approvals")
local PendingPrompts = require("vibing.infrastructure.rpc.pending_prompts")

describe("pending native approvals", function()
  after_each(function()
    PendingNative._reset()
  end)

  --- @return table decisions every decision the entry was answered with, in order
  local function open(request_id, extra)
    local decisions = {}
    PendingNative.open(vim.tbl_extend("force", {
      request_id = request_id,
      chat_bufnr = 1,
      tool = "Codex command execution",
      respond = function(decision)
        table.insert(decisions, decision)
      end,
    }, extra or {}))
    return decisions
  end

  describe("every response is owed", function()
    it("writes the human's decision back to the waiting request", function()
      local decisions = open("codex-p1-0")

      assert.is_true(PendingNative.resolve("codex-p1-0", "accept"))
      assert.same({ "accept" }, decisions)
    end)

    it("keeps an object decision exactly as the CLI offered it", function()
      -- The amendment bodies are the part most likely to grow a field, so they travel verbatim
      -- rather than being rebuilt from the option's slug.
      local decisions = open("codex-p1-0")
      local raw = { acceptWithExecpolicyAmendment = { execpolicy_amendment = { "/bin/zsh", "-lc", "ls" } } }

      PendingNative.resolve("codex-p1-0", raw)
      assert.same(raw, decisions[1])
    end)

    it("responds exactly once, however many exits reach the same request", function()
      local decisions = open("codex-p1-0")

      assert.is_true(PendingNative.resolve("codex-p1-0", "accept"))
      assert.is_false(PendingNative.resolve("codex-p1-0", "decline"))
      assert.is_false(PendingNative.expire("codex-p1-0"))
      assert.equals(0, PendingNative.resolve_for_chat(1, "gone"))
      assert.equals(0, PendingNative.resolve_all("exiting"))
      assert.same({ "accept" }, decisions)
    end)

    it("still drops the entry when the write itself fails", function()
      -- The process it answers can die at any point in the wait. Holding the entry open after a
      -- failed write would only make the sweeps report work they cannot do.
      PendingNative.open({
        request_id = "codex-p1-0",
        chat_bufnr = 1,
        respond = function()
          error("the process is gone")
        end,
      })

      assert.is_true(PendingNative.resolve("codex-p1-0", "accept"))
      assert.is_nil(PendingNative.get("codex-p1-0"))
    end)
  end)

  describe("the wait limit", function()
    it("declines that one call and says so, without ending anything", function()
      local told = {}
      local decisions = open("codex-p1-0", {
        on_timeout = function(entry)
          table.insert(told, entry.request_id)
        end,
      })

      assert.is_true(PendingNative.expire("codex-p1-0"))
      assert.same({ "decline" }, decisions)
      assert.same({ "codex-p1-0" }, told)
    end)

    it("releases the request before telling the chat about it", function()
      -- The same ordering both siblings keep: an expired prompt must never find a live registry
      -- entry and take the in-place route against a decision that was already sent.
      local seen_during_timeout
      open("codex-p1-0", {
        on_timeout = function()
          seen_during_timeout = PendingNative.get("codex-p1-0")
        end,
      })

      PendingNative.expire("codex-p1-0")
      assert.is_nil(seen_during_timeout)
    end)

    it("survives a timeout callback that throws", function()
      local decisions = open("codex-p1-0", {
        on_timeout = function()
          error("the buffer went away")
        end,
      })

      assert.is_true(PendingNative.expire("codex-p1-0"))
      assert.same({ "decline" }, decisions)
    end)
  end)

  describe("the fifth exit: codex resolved it itself", function()
    it("drops the entry and writes nothing", function()
      -- Answering now would name an id codex no longer holds.
      local decisions = open("codex-p1-0")

      assert.is_true(PendingNative.forget("codex-p1-0"))
      assert.same({}, decisions)
      assert.is_nil(PendingNative.get("codex-p1-0"))
    end)

    it("reports nothing to forget when the human answered first", function()
      open("codex-p1-0")
      PendingNative.resolve("codex-p1-0", "accept")

      assert.is_false(PendingNative.forget("codex-p1-0"))
    end)
  end)

  describe("the sweeps", function()
    it("declines every request of one chat and leaves the others alone", function()
      local mine = open("codex-p1-0", { chat_bufnr = 7 })
      local theirs = open("codex-p2-0", { chat_bufnr = 8 })

      assert.equals(1, PendingNative.resolve_for_chat(7, "the chat went away"))
      assert.same({ "decline" }, mine)
      assert.same({}, theirs)
    end)

    it("declines everything left when Neovim exits", function()
      local a = open("codex-p1-0", { chat_bufnr = 7 })
      local b = open("codex-p2-0", { chat_bufnr = 8 })

      assert.equals(2, PendingNative.resolve_all("Neovim exited"))
      assert.same({ "decline" }, a)
      assert.same({ "decline" }, b)
    end)

    it("re-opening one id declines the first owner rather than replacing it silently", function()
      local first = open("codex-p1-0")
      local second = open("codex-p1-0")

      assert.same({ "decline" }, first)
      assert.same({}, second)
    end)
  end)

  describe("the shared exits reach this channel too", function()
    it("is swept by pending_prompts, which is where every chat-level exit goes", function()
      -- Being listed in `pending_prompts.CHANNELS` is the whole reason cancelling a turn, closing
      -- the chat and quitting Neovim need no code of their own here.
      local decisions = open("codex-p1-0", { chat_bufnr = 42 })

      assert.is_true(PendingPrompts.has_for_chat(42))
      assert.is_true(PendingPrompts.resolve_for_chat(42, "The turn this %s belonged to was cancelled.") >= 1)
      assert.same({ "decline" }, decisions)
      assert.is_false(PendingPrompts.has_for_chat(42))
    end)

    it("is swept by pending_prompts.resolve_all", function()
      local decisions = open("codex-p1-0", { chat_bufnr = 42 })

      assert.is_true(PendingPrompts.resolve_all("Neovim exited while this %s was waiting.") >= 1)
      assert.same({ "decline" }, decisions)
    end)
  end)
end)
