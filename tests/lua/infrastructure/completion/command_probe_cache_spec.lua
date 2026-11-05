-- The cache keys one answer per backend. Before this, one list served every chat, which was only
-- safe while a single backend had a probe: with two, a Codex chat would be offered Claude's
-- `/design`. The probe itself is replaced here -- what is pinned is the bookkeeping around it.

local fetches = {}

package.loaded["vibing.infrastructure.completion.command_probe"] = {
  fetch = function(probe, opts, callback)
    table.insert(fetches, { probe = probe, opts = opts, callback = callback })
    return true
  end,
  is_known = function()
    return true
  end,
}

local Cache = require("vibing.infrastructure.completion.providers.command_probe_cache")

local PROBE = { protocol = "acp", args = { "acp" } }

describe("command_probe_cache", function()
  local original_cwd = vim.fn.getcwd()

  before_each(function()
    fetches = {}
    Cache.clear()
  end)

  after_each(function()
    vim.cmd.cd(original_cwd)
  end)

  it("keeps one answer per backend", function()
    Cache.start("claude", PROBE, function() end)
    Cache.start("codex", PROBE, function() end)
    fetches[1].callback({ { name = "design" } })

    assert.equals("design", Cache.peek("claude")[1].name)
    assert.is_nil(Cache.peek("codex"))
    assert.is_true(Cache.is_loading("codex"))
    assert.is_false(Cache.is_loading("claude"))
  end)

  it("hands the probe the backend it is asking for", function()
    Cache.start("codex", PROBE, function() end)

    assert.equals("codex", fetches[1].opts.agent)
    assert.equals("codex", fetches[1].opts.descriptor.id)
    assert.equals(vim.fn.getcwd(-1, -1), fetches[1].opts.cwd)
  end)

  it("does not start a second probe while one is running or after it answered", function()
    Cache.start("claude", PROBE, function() end)
    Cache.start("claude", PROBE, function() end)
    assert.equals(1, #fetches)

    fetches[1].callback({ { name = "design" } })
    Cache.start("claude", PROBE, function() end)
    assert.equals(1, #fetches)
  end)

  it("tells the caller when an answer lands", function()
    local landed = 0
    Cache.start("claude", PROBE, function()
      landed = landed + 1
    end)
    fetches[1].callback({ { name = "design" } })

    assert.equals(1, landed)
  end)

  it("caches nothing on failure and waits out a cooldown before retrying", function()
    local landed = false
    Cache.start("claude", PROBE, function()
      landed = true
    end)
    fetches[1].callback(nil)

    assert.is_false(landed)
    assert.is_nil(Cache.peek("claude"))
    assert.is_false(Cache.is_loading("claude"))

    -- A completion trigger straight after must not respawn the CLI.
    Cache.start("claude", PROBE, function() end)
    assert.equals(1, #fetches)
  end)

  it("lets :VibingReloadCommands skip the cooldown", function()
    Cache.start("claude", PROBE, function() end)
    fetches[1].callback(nil)

    Cache.clear()
    Cache.start("claude", PROBE, function() end)

    assert.equals(2, #fetches)
  end)

  it("drops every backend's answer when the directory moves", function()
    Cache.start("claude", PROBE, function() end)
    Cache.start("codex", PROBE, function() end)
    fetches[1].callback({ { name = "design" } })
    fetches[2].callback({ { name = "imagegen" } })
    assert.is_false(Cache.invalidate_if_stale())

    local elsewhere = vim.fn.tempname()
    vim.fn.mkdir(elsewhere, "p")
    vim.cmd.cd(elsewhere)

    assert.is_true(Cache.invalidate_if_stale())
    assert.is_nil(Cache.peek("claude"))
    assert.is_nil(Cache.peek("codex"))
  end)

  it("ignores an answer to a question the cache has since dropped", function()
    local landed = false
    Cache.start("claude", PROBE, function()
      landed = true
    end)
    Cache.clear()
    fetches[1].callback({ { name = "design" } })

    assert.is_false(landed)
    assert.is_nil(Cache.peek("claude"))
  end)

  it("does not mistake an agent that was never probed for a stale one", function()
    assert.is_false(Cache.invalidate_if_stale())
    assert.is_nil(Cache.peek("grok"))
    assert.is_false(Cache.is_loading("grok"))
  end)
end)
