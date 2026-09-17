---@diagnostic disable: undefined-field
--- Which process model a turn runs under (#777).
---
--- The default matters more than the feature: `duplex` is opt-in, so every assertion here that ends
--- in `oneshot` is guarding against a resident process appearing where nobody asked for one.
local ProcessModel = require("vibing.infrastructure.adapter.modules.process_model")

local CAPABLE = { id = "claude", process = "duplex" }
local INCAPABLE = { id = "codex" }

--- The minimum for a turn that *could* be duplex, so each test varies one thing.
--- @param extra table?
--- @return table
local function opts(extra)
  return vim.tbl_extend("force", { chat_bufnr = 7 }, extra or {})
end

--- @param value string?
--- @return table
local function config_with(value)
  return { backends = { claude = { process = value } } }
end

describe("process_model.resolve", function()
  local notified, original_notify

  before_each(function()
    notified = {}
    ProcessModel._reset_announcements()
    original_notify = vim.notify
    vim.notify = function(message, level)
      table.insert(notified, { message = message, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  it("is oneshot with nothing configured, on a backend that could do better", function()
    assert.equals("oneshot", ProcessModel.resolve(CAPABLE, opts(), {}))
  end)

  it("takes duplex from backends.<id>.process", function()
    assert.equals("duplex", ProcessModel.resolve(CAPABLE, opts(), config_with("duplex")))
  end)

  it("lets the chat's own frontmatter override the backend setting, in both directions", function()
    assert.equals("oneshot", ProcessModel.resolve(CAPABLE, opts({ process = "oneshot" }), config_with("duplex")))
    assert.equals("duplex", ProcessModel.resolve(CAPABLE, opts({ process = "duplex" }), config_with("oneshot")))
  end)

  it("refuses duplex on a backend whose descriptor does not declare it, and says so", function()
    -- `descriptor.process` is the ceiling, not the default: a CLI that cannot read a prompt from
    -- stdin must not be handed one because a config key said so.
    --
    -- Announced because this refusal is invisible everywhere else. `config.lua`'s validation walks
    -- only *declared* fields, so `backends.codex.process = "duplex"` is not even rejected there --
    -- the chat would run exactly as before and the user would measure a feature they never got.
    assert.equals("oneshot", ProcessModel.resolve(INCAPABLE, opts({ process = "duplex" }), config_with("duplex")))
    assert.equals(1, #notified)
    assert.equals(vim.log.levels.WARN, notified[1].level)
    assert.matches("codex", notified[1].message)
  end)

  it("says it once, not once per turn", function()
    for _ = 1, 4 do
      ProcessModel.resolve(INCAPABLE, opts({ process = "duplex" }), {})
    end
    assert.equals(1, #notified)
  end)

  it("says nothing at all when nobody asked for duplex", function()
    ProcessModel.resolve(INCAPABLE, opts(), {})
    ProcessModel.resolve(CAPABLE, opts(), {})
    assert.same({}, notified)
  end)

  it("holds a lightweight call at oneshot however it was asked, and silently", function()
    -- core/types.lua's bargain -- no tools, no project config, no user MCP servers, no hooks,
    -- utility_model -- is not something a process serving a chat can also be keeping. Silent
    -- because this is title generation and /summarize, not a chat anyone is watching for speed.
    local resolved = ProcessModel.resolve(CAPABLE, opts({ process = "duplex", lightweight = true }), config_with("duplex"))
    assert.equals("oneshot", resolved)
    assert.same({}, notified)
  end)

  it("holds a subagent chat at oneshot however it was asked, and says so", function()
    -- A subagent chat shares its parent's session permanently, and a resident process holds its
    -- `--resume` for its whole life: two of them would sit on one transcript indefinitely. Unlike
    -- the lightweight case this is a chat the user opened and is watching.
    local resolved = ProcessModel.resolve(CAPABLE, opts({ process = "duplex", _subagent_id = "sub-1" }), config_with("duplex"))
    assert.equals("oneshot", resolved)
    assert.equals(1, #notified)
    assert.matches("subagent", notified[1].message)
  end)

  it("holds a turn with no chat to key a process on at oneshot", function()
    local resolved = ProcessModel.resolve(CAPABLE, { process = "duplex" }, config_with("duplex"))
    assert.equals("oneshot", resolved)
  end)

  it("falls back to oneshot and says so when the value is not a process model", function()
    local ok, resolved = pcall(ProcessModel.resolve, CAPABLE, opts({ process = "residnet" }), {})

    assert.is_true(ok)
    assert.equals("oneshot", resolved)
    assert.equals(1, #notified)
    assert.equals(vim.log.levels.WARN, notified[1].level)
    assert.matches("frontmatter", notified[1].message)
  end)

  it("does not read the backend setting past a bad frontmatter value", function()
    -- Falling through to `backends.claude.process = "duplex"` after refusing the chat's own value
    -- would give the chat the opposite of the safe answer for a typo.
    assert.equals("oneshot", ProcessModel.resolve(CAPABLE, opts({ process = "" }), config_with("duplex")))
  end)
end)
