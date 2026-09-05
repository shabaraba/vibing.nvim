-- サブエージェントを起動しうるコマンドが複数チャットへ同報されたら警告する（#700）。
-- 実際のサブエージェント数は数えず、コマンド名の一致と直近の送信先だけで判定する。

local Config = require("vibing.config")

describe("SubagentBroadcast", function()
  local Broadcast
  local originals = {}
  local warnings = {}

  ---@param orchestration table?
  local function configure(orchestration)
    Config.get = function()
      return { agent = { orchestration = orchestration } }
    end
  end

  before_each(function()
    originals.get = Config.get
    warnings = {}

    package.loaded["vibing.application.chat.subagent_broadcast"] = nil
    Broadcast = require("vibing.application.chat.subagent_broadcast")

    originals.warn = require("vibing.core.utils.notify").warn
    require("vibing.core.utils.notify").warn = function(message, action)
      table.insert(warnings, { message = message, action = action })
    end

    configure({ subagent_spawning_commands = { "simplify", "code-review" } })
  end)

  after_each(function()
    Config.get = originals.get
    require("vibing.core.utils.notify").warn = originals.warn
    if originals.time then
      os.time = originals.time
      originals.time = nil
    end
  end)

  ---@param seconds number
  local function at(seconds)
    originals.time = originals.time or os.time
    os.time = function()
      return seconds
    end
  end

  it("does not warn on a single target", function()
    Broadcast.check(1, 10, "/simplify")

    assert.equals(0, #warnings)
  end)

  it("warns once a second distinct chat receives the same spawning command", function()
    Broadcast.check(1, 10, "/simplify")
    Broadcast.check(1, 11, "/simplify")

    assert.equals(1, #warnings)
    assert.is_truthy(warnings[1].message:find("/simplify", 1, true))
    assert.is_truthy(warnings[1].message:find("2", 1, true))
    assert.is_truthy(warnings[1].message:find("#692", 1, true))
    assert.equals("Orchestration", warnings[1].action)
  end)

  it("does not warn again for a third target in the same window", function()
    Broadcast.check(1, 10, "/simplify")
    Broadcast.check(1, 11, "/simplify")
    Broadcast.check(1, 12, "/simplify")

    assert.equals(1, #warnings)
  end)

  it("does not warn for the same target sent to twice", function()
    Broadcast.check(1, 10, "/simplify")
    Broadcast.check(1, 10, "/simplify")

    assert.equals(0, #warnings)
  end)

  it("ignores a command that is not in the configured list", function()
    Broadcast.check(1, 10, "/review")
    Broadcast.check(1, 11, "/review")

    assert.equals(0, #warnings)
  end)

  it("ignores a plain message with no leading slash command", function()
    Broadcast.check(1, 10, "please run /simplify later")
    Broadcast.check(1, 11, "please run /simplify later")

    assert.equals(0, #warnings)
  end)

  it("does not confuse different senders broadcasting the same command", function()
    Broadcast.check(1, 10, "/simplify")
    Broadcast.check(2, 11, "/simplify")

    assert.equals(0, #warnings)
  end)

  it("does not track a send with no from_bufnr, so unrelated anonymous callers never collide", function()
    Broadcast.check(nil, 10, "/simplify")
    Broadcast.check(nil, 11, "/simplify")

    assert.equals(0, #warnings)
  end)

  it("expires the window from the first send, not from whichever send is most recent", function()
    configure({ subagent_spawning_commands = { "simplify" }, broadcast_warn_window_sec = 30 })

    at(0)
    Broadcast.check(1, 10, "/simplify")
    at(5)
    Broadcast.check(1, 11, "/simplify") -- 2nd distinct target inside the window: warns once
    at(20)
    Broadcast.check(1, 10, "/simplify") -- repeat traffic; must not push the window out further

    -- Past first_seen + window: a fresh window starts, so this is only its 1st distinct target
    at(40)
    Broadcast.check(1, 12, "/simplify")
    -- ...and this is its 2nd distinct target, which must warn again on its own new window
    -- rather than staying silent because the earlier window's `warned` flag never expired.
    at(41)
    Broadcast.check(1, 13, "/simplify")

    assert.equals(2, #warnings)
  end)

  it("is silent when the window is disabled", function()
    configure({ subagent_spawning_commands = { "simplify" }, broadcast_warn_window_sec = 0 })

    Broadcast.check(1, 10, "/simplify")
    Broadcast.check(1, 11, "/simplify")

    assert.equals(0, #warnings)
  end)

  it("survives a broken orchestration setting instead of erroring on every send", function()
    configure(true)

    assert.has_no.errors(function()
      Broadcast.check(1, 10, "/simplify")
      Broadcast.check(1, 11, "/simplify")
    end)
    assert.equals(0, #warnings)
  end)

  it("uses the configured command list instead of the default once one is given", function()
    configure({ subagent_spawning_commands = { "review-mine" } })

    Broadcast.check(1, 10, "/simplify")
    Broadcast.check(1, 11, "/simplify")
    assert.equals(0, #warnings)

    Broadcast.check(1, 20, "/review-mine")
    Broadcast.check(1, 21, "/review-mine")
    assert.equals(1, #warnings)
  end)
end)
