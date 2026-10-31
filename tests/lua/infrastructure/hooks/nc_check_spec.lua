--- `nc` is the hook scripts' only way to wake Neovim. A missing binary fails closed inside
--- `pre-tool-use.sh`, and until the warning below existed the chat showed the same "Failed to
--- connect" it shows for a dead RPC server. The warning belongs on hook install: that is the
--- shared seam every backend passes through before the script runs, and a lightweight call never
--- reaches it.
describe("hook install warns when nc is missing", function()
  local Transports = require("vibing.infrastructure.hooks.transports")
  local Settings = require("vibing.infrastructure.hooks.settings_generator")
  local original_executable
  local original_ensure
  local original_notify

  before_each(function()
    original_executable = vim.fn.executable
    original_ensure = Settings.ensure
    original_notify = vim.notify
    -- warn_once memoises for the life of the notify module.
    package.loaded["vibing.core.utils.notify"] = nil
    Settings.ensure = function()
      return "/tmp/hook-settings.json"
    end
  end)

  after_each(function()
    vim.fn.executable = original_executable
    vim.notify = original_notify
    Settings.ensure = original_ensure
    package.loaded["vibing.core.utils.notify"] = nil
  end)

  local function install()
    return Transports.install({ transport = "settings_file" }, "/tmp")
  end

  it("warns once and still registers the hook", function()
    local messages = {}
    vim.notify = function(message, level)
      table.insert(messages, { message = message, level = level })
    end
    vim.fn.executable = function(name)
      if name == "nc" then
        return 0
      end
      return original_executable(name)
    end

    assert.equals("/tmp/hook-settings.json", install())
    assert.equals("/tmp/hook-settings.json", install())

    assert.equals(1, #messages)
    assert.equals(vim.log.levels.WARN, messages[1].level)
    assert.is_truthy(messages[1].message:find("netcat (nc)", 1, true))
    assert.is_truthy(messages[1].message:find("Install nc", 1, true))
  end)

  it("stays quiet when nc is on PATH", function()
    local messages = {}
    vim.notify = function(message, level)
      table.insert(messages, { message = message, level = level })
    end
    vim.fn.executable = function(name)
      if name == "nc" then
        return 1
      end
      return original_executable(name)
    end

    assert.equals("/tmp/hook-settings.json", install())
    assert.equals(0, #messages)
  end)
end)
