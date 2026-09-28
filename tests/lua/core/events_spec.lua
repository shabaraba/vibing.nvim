-- `VibingResponseDone` has several subscribers and no ordering between them: `treesitter_fold`
-- registers when the first chat window opens, ahead of the two that register in `setup()`, so the
-- order is an accident of require order.
--
-- Whether one of them throwing costs the rest is decided by the *caller*, which none of them can
-- see -- the first pair below pins both halves of that. A stale `parser/vibing.so` made it matter:
-- the fold query threw on every turn until Neovim was restarted, from the one subscriber that
-- happens to be registered first.
--
-- So the property asserted here is the one the wrapper buys, not one the chain provides: a
-- subscriber that throws costs nothing but itself, whoever fired the event.

local Events = require("vibing.core.events")

describe("VibingResponseDone subscribers", function()
  local group
  local notifications
  local original_notify

  before_each(function()
    group = vim.api.nvim_create_augroup("VibingEventsSpec", { clear = true })
    notifications = {}
    original_notify = vim.notify
    vim.notify = function(msg)
      table.insert(notifications, msg)
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.api.nvim_del_augroup_by_id(group)
  end)

  -- The event carries the buffer in `data`, which `:doautocmd` cannot set -- so a Vim command
  -- context means a `:lua` chunk, which is also exactly how the abort was first measured.
  local function fire_from_a_vim_command(bufnr)
    pcall(
      vim.cmd,
      ('lua vim.api.nvim_exec_autocmds("User", { pattern = %q, data = { bufnr = %d } })'):format(
        Events.RESPONSE_DONE,
        bufnr
      )
    )
  end

  -- Both firing contexts, because only one of them can tell the wrapper from its absence: from Lua
  -- the chain carries on by itself, so asserting this on `emit` alone passes with the `pcall`
  -- deleted. That is the vacuous version of this exact test, and it was written first.
  it("keeps running the later ones when an earlier one throws", function()
    local function chain()
      local reached = {}
      Events.on_response_done(group, "first", function()
        table.insert(reached, "first")
        error("the fold query did not compile")
      end)
      Events.on_response_done(group, "second", function(bufnr)
        table.insert(reached, "second:" .. bufnr)
      end)
      return reached
    end

    local from_lua = chain()
    Events.emit_response_done(7)
    assert.same({ "first", "second:7" }, from_lua)

    vim.api.nvim_clear_autocmds({ group = group })

    local from_a_command = chain()
    fire_from_a_vim_command(7)
    assert.same({ "first", "second:7" }, from_a_command)
  end)

  it("names the subscriber that threw", function()
    Events.on_response_done(group, "chat folding", function()
      error('Invalid node type "thinking_block"')
    end)

    Events.emit_response_done(7)

    assert.equals(1, #notifications)
    assert.is_truthy(notifications[1]:find("chat folding", 1, true))
    assert.is_truthy(notifications[1]:find("thinking_block", 1, true))
  end)

  it("reaches no subscriber for an event that carries no buffer", function()
    local reached = 0
    Events.on_response_done(group, "counter", function()
      reached = reached + 1
    end)

    vim.api.nvim_exec_autocmds("User", { pattern = Events.RESPONSE_DONE })
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.RESPONSE_DONE,
      data = { bufnr = "7" },
    })

    assert.equals(0, reached)
  end)

  -- Whether a throwing subscriber costs the ones behind it depends on **where the event was
  -- fired from**, which no subscriber can see. Measured: from Lua the chain carries on and Neovim
  -- just reports the error; from a Vim command context (`:doautocmd`, or a `:lua` chunk) it
  -- aborts. `emit_response_done` is on the first of those today, so this is not a live failure --
  -- it is the reason a subscriber must not throw at all, rather than a reason to trust the chain.
  describe("a subscriber that registered its own autocmd", function()
    local function chain_with_a_raw_thrower()
      local reached = false
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = Events.RESPONSE_DONE,
        callback = function()
          error("a subscriber that bypassed on_response_done")
        end,
      })
      Events.on_response_done(group, "behind it", function()
        reached = true
      end)
      return function()
        return reached
      end
    end

    it("costs the ones behind it when the event is fired from a Vim command", function()
      local reached = chain_with_a_raw_thrower()

      fire_from_a_vim_command(7)

      assert.is_false(reached())
    end)

    it("is survived when the same event is fired from Lua, as emit does", function()
      local reached = chain_with_a_raw_thrower()

      assert.has_no.errors(function()
        Events.emit_response_done(7)
      end)

      assert.is_true(reached())
      -- Neovim reported it; nothing came back through `nvim_exec_autocmds` for `emit` to catch.
      assert.equals(0, #notifications)
    end)
  end)

end)

describe("VibingResponseDone call sites", function()
  -- Rooted at this spec's own path rather than the cwd, for the reason `mkdir_call_sites_spec`
  -- states: `test:lua` passes a relative `-u`, so a cwd-rooted scan reports on whichever checkout
  -- the command happened to be typed in.
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local owner = "lua/vibing/core/events.lua"

  before_each(function()
    assert.equals(
      1,
      vim.fn.filereadable(root .. "/" .. owner),
      "repo root resolved to " .. root .. " -- has this spec moved? the ':h' count follows it"
    )
  end)

  -- Naming the event in prose is free; every file that subscribes explains why it does. What the
  -- scan is about is *using* it -- a registration that bypasses `on_response_done` is a subscriber
  -- that can take the others down with it again.
  local function code_hits(pattern)
    local hits = vim.fn.systemlist({ "grep", "-rn", pattern, root .. "/lua" })
    local out = {}
    for _, line in ipairs(hits) do
      local text = line:match("^[^:]+:%d+:(.*)$") or ""
      if not text:match("^%s*%-%-") then
        table.insert(out, (line:gsub("^" .. vim.pesc(root) .. "/", "")))
      end
    end
    return out
  end

  it("name the event only in core/events.lua", function()
    local hits = code_hits("VibingResponseDone")

    local offenders = {}
    for _, line in ipairs(hits) do
      if not line:match(vim.pesc(owner)) then
        table.insert(offenders, line)
      end
    end

    -- Positive control: events.lua assigns the name, so an empty result means the grep read the
    -- wrong tree rather than that the tree is clean.
    assert.is_true(#hits > 0, "the grep found nothing at all in lua/")
    assert.equals(
      0,
      #offenders,
      "subscribe through Events.on_response_done instead:\n" .. table.concat(offenders, "\n")
    )
  end)

  it("fire it from core/events.lua alone", function()
    local hits = code_hits("nvim_exec_autocmds")

    local offenders = {}
    for _, line in ipairs(hits) do
      if not line:match(vim.pesc(owner)) then
        table.insert(offenders, line)
      end
    end

    assert.is_true(#hits > 0, "the grep found nothing at all in lua/")
    assert.equals(0, #offenders, "autocmd fired outside events.lua:\n" .. table.concat(offenders, "\n"))
  end)
end)
