---@diagnostic disable: undefined-field
--- The `string_list` kind in `backends.<id>` validation.
---
--- It is the first `config_fields` kind whose default is a table, which is the whole reason these
--- assertions exist: a table default handed out by reference makes `M.defaults` writable through
--- whatever the user passed to `setup()`.
local Config = require("vibing.config")

describe("backends.<id> string_list fields", function()
  local original_notify, notified

  before_each(function()
    notified = {}
    original_notify = vim.notify
    vim.notify = function(message)
      table.insert(notified, message)
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  --- @param value any what to put in `backends.codex.auto_approve_ask`
  --- @return any stored
  local function setup_with(value)
    Config.setup({ backends = { codex = { auto_approve_ask = value } } })
    return Config.get().backends.codex.auto_approve_ask
  end

  it("keeps a list of non-empty strings as the user wrote it", function()
    assert.same({ "Bash(git push)", "Bash(rm:*)" }, setup_with({ "Bash(git push)", "Bash(rm:*)" }))
  end)

  it("defaults to an empty list", function()
    assert.same({}, setup_with(nil))
  end)

  it("rejects the list whole rather than filtering it", function()
    -- A shorter list that still looks like the user's own is worse than an obvious reset: these
    -- entries are permission rules, and a silently dropped one is an exception that stopped
    -- existing.
    assert.same({}, setup_with({ "Bash(rm:*)", 42 }))
    assert.equals(1, #notified)
  end)

  it("rejects a map-shaped table, which ipairs would read as empty", function()
    assert.same({}, setup_with({ ask = "Bash(rm:*)" }))
    assert.same({}, setup_with("Bash(rm:*)"))
  end)

  it("does not hand back the literal in agents.lua, which every reader of it shares", function()
    -- Only that decoupling is asserted. `options.backends.<id>` still *is* `M.defaults.backends
    -- .<id>` when `setup()` gets no `backends` key -- `tbl_deep_extend` hands the subtree over by
    -- reference -- which is older than this field, true of every table default, and not fixed here.
    local Agents = require("vibing.core.constants.agents")

    assert.is_false(rawequal(Config.defaults.backends.codex.auto_approve_ask, Agents.config_fields("codex").auto_approve_ask.default))
  end)
end)
