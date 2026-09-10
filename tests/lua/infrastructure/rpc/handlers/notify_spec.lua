describe("rpc handler notify", function()
  local notify = require("vibing.infrastructure.rpc.handlers.notify")

  local original_notify
  local shown

  before_each(function()
    shown = {}
    original_notify = vim.notify
    vim.notify = function(message, level)
      table.insert(shown, { message = message, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  it("shows the message at the requested level", function()
    local result = notify.notify({ message = "rebuilt", level = "error", title = "MCP Server" })

    assert.is_true(result.success)
    assert.equals(1, #shown)
    assert.equals("[vibing] MCP Server: rebuilt", shown[1].message)
    assert.equals(vim.log.levels.ERROR, shown[1].level)
  end)

  it("shows a message whose level it does not recognise rather than dropping it", function()
    -- The MCP server launcher is the caller, and it has no second channel to report a bad level
    -- on: the whole point of this handler is that its stderr reaches nobody (#690).
    notify.notify({ message = "something happened", level = "catastrophe" })

    assert.equals(1, #shown)
    assert.equals(vim.log.levels.INFO, shown[1].level)
  end)

  it("refuses a call with no message", function()
    assert.has_error(function()
      notify.notify({ level = "warn" })
    end)
    assert.has_error(function()
      notify.notify({ message = "" })
    end)
    assert.equals(0, #shown)
  end)

  it("is reachable under the name the launcher sends", function()
    assert.equals(notify.notify, require("vibing.infrastructure.rpc.handlers").notify)
  end)
end)
