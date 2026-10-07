---@diagnostic disable: undefined-field
--- `backends.codex.auto_approve_ask`: the exceptions that reach a human anyway.
---
--- The list can only ever send a request **to** a human, so every assertion here is about one of two
--- things: that a rule the user wrote fires, and that a shape the request can arrive in does not
--- quietly slip past it.
local Rules = require("vibing.infrastructure.adapter.modules.codex_auto_approve_rules")

local COMMAND = "item/commandExecution/requestApproval"
local FILE_CHANGE = "item/fileChange/requestApproval"

describe("codex auto_approve exceptions", function()
  describe("an empty list", function()
    it("asks for nothing, which is auto_approve on its own", function()
      assert.is_false(Rules.must_ask(COMMAND, { command = "git push origin main" }, nil, {}))
      assert.is_false(Rules.must_ask(COMMAND, { command = "git push origin main" }, nil, nil))
    end)
  end)

  describe("a command approval", function()
    it("asks when the command matches a rule the user wrote", function()
      assert.is_true(Rules.must_ask(COMMAND, { command = "git push origin main" }, nil, { "Bash(git push)" }))
      assert.is_true(Rules.must_ask(COMMAND, { command = "git push origin main" }, nil, { "Bash(git:*)" }))
    end)

    it("auto-answers a command no rule names", function()
      assert.is_false(Rules.must_ask(COMMAND, { command = "git status" }, nil, { "Bash(git push)" }))
    end)

    it("reads the same grammar permissions.ask does, so one rule shape covers both", function()
      -- Evaluated by `matchers.matches_permission`; a second implementation is what this avoids.
      assert.is_true(Rules.must_ask(COMMAND, { command = "rm -rf build" }, nil, { "Bash(rm:*)" }))
      assert.is_true(Rules.must_ask(COMMAND, { command = "anything at all" }, nil, { "Bash" }))
    end)

    it("auto-answers a request carrying no command, rather than asking about nothing", function()
      -- Treating unreadable as "ask" would make a non-empty list prompt for everything.
      assert.is_false(Rules.must_ask(COMMAND, {}, nil, { "Bash(git push)" }))
      assert.is_false(Rules.must_ask(COMMAND, { command = "" }, nil, { "Bash(git push)" }))
      assert.is_false(Rules.must_ask(COMMAND, nil, nil, { "Bash(git push)" }))
    end)
  end)

  describe("a rule matchers.lua can never make fire", function()
    local notified, original_notify

    before_each(function()
      notified = {}
      -- `warn_once` memoises for the life of the module, so the module and its caller are dropped
      -- together -- reloading only notify would leave Rules holding the old memo.
      package.loaded["vibing.core.utils.notify"] = nil
      package.loaded["vibing.infrastructure.adapter.modules.codex_auto_approve_rules"] = nil
      Rules = require("vibing.infrastructure.adapter.modules.codex_auto_approve_rules")
      original_notify = vim.notify
      vim.notify = function(message)
        table.insert(notified, message)
      end
    end)

    after_each(function()
      vim.notify = original_notify
      package.loaded["vibing.core.utils.notify"] = nil
      package.loaded["vibing.infrastructure.adapter.modules.codex_auto_approve_rules"] = nil
      Rules = require("vibing.infrastructure.adapter.modules.codex_auto_approve_rules")
    end)

    it("says so, instead of silently matching nothing", function()
      -- `Bash(x:*)` compares only the command's first word, so a multi-word prefix is dead. Silent
      -- is the failure mode that matters: the user believes the exception is in place.
      Rules.must_ask(COMMAND, { command = "git push origin main" }, nil, { "Bash(git push:*)" })

      assert.equals(1, #notified)
      assert.is_not_nil(notified[1]:find("can never match", 1, true))
      assert.is_not_nil(notified[1]:find("Bash(git push)", 1, true))
    end)

    it("stays quiet about a single-word wildcard, which does fire", function()
      Rules.must_ask(COMMAND, { command = "git push origin main" }, nil, { "Bash(git:*)", "Bash(rm:*)" })

      assert.same({}, notified)
    end)
  end)

  describe("a file-change approval", function()
    local function changes(...)
      local out = {}
      for _, path in ipairs({ ... }) do
        table.insert(out, { path = path, kind = "update" })
      end
      return out
    end

    it("asks when any path in the envelope matches, not only the first", function()
      -- A codex patch carries several paths at once. Matching the first alone is an evasion by
      -- patch ordering, the one `architecture.md` already records.
      local rules = { "Edit(/etc/**)" }

      assert.is_true(Rules.must_ask(FILE_CHANGE, {}, changes("/etc/hosts"), rules))
      assert.is_true(Rules.must_ask(FILE_CHANGE, {}, changes("/tmp/a.txt", "/etc/hosts"), rules))
    end)

    it("tests a path under both Edit and Write, since the request says neither", function()
      local path = changes("/etc/hosts")

      assert.is_true(Rules.must_ask(FILE_CHANGE, {}, path, { "Edit(/etc/**)" }))
      assert.is_true(Rules.must_ask(FILE_CHANGE, {}, path, { "Write(/etc/**)" }))
    end)

    it("reads the legacy method's own fileChanges when no item changes were remembered", function()
      local params = { fileChanges = { { path = "/etc/hosts", kind = "update" } } }

      assert.is_true(Rules.must_ask(FILE_CHANGE, params, nil, { "Edit(/etc/**)" }))
    end)

    it("auto-answers when no path matches, and when there are no paths at all", function()
      assert.is_false(Rules.must_ask(FILE_CHANGE, {}, changes("/tmp/a.txt"), { "Edit(/etc/**)" }))
      assert.is_false(Rules.must_ask(FILE_CHANGE, {}, nil, { "Edit(/etc/**)" }))
      assert.is_false(Rules.must_ask(FILE_CHANGE, {}, {}, { "Edit(/etc/**)" }))
    end)
  end)
end)
