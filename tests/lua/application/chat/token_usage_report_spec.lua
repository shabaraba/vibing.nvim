local SendMessage = require("vibing.application.chat.send_message")
local TokenUsage = require("vibing.core.utils.token_usage")

describe("send_message._report_token_usage", function()
  local function harness()
    local state = { chunks = {} }
    local callbacks = {
      append_chunk = function(chunk)
        table.insert(state.chunks, chunk)
      end,
    }
    return state, callbacks
  end

  local function usage_of(context, requests)
    local acc = TokenUsage.new()
    acc.requests = requests or 1
    acc.context = context
    acc.read = context * (requests or 1)
    acc.write = 5000
    return acc
  end

  --- Anything the reporter writes, as one string.
  local function written(state)
    return table.concat(state.chunks, "")
  end

  it("appends the turn's breakdown as its own section", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage({ _token_usage = usage_of(120000, 12) }, callbacks, {})

    assert.truthy(written(state):find("### Tokens", 1, true))
    assert.truthy(written(state):find("context 120k", 1, true))
    assert.truthy(written(state):find("12 requests", 1, true))
  end)

  it("stays silent for a backend that reports no usage", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage({}, callbacks, {})

    assert.equals("", written(state))
  end)

  it("writes nothing at all when the feature is switched off", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage(
      { _token_usage = usage_of(900000, 30) },
      callbacks,
      { agent = { token_usage = { enabled = false } } }
    )

    assert.equals("", written(state))
  end)

  it("puts the warning inside the section, under the metrics", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage({ _token_usage = usage_of(310000, 20) }, callbacks, {})

    local text = written(state)
    local heading_at = text:find("### Tokens", 1, true)
    local metrics_at = text:find("context 310k", 1, true)
    local warning_at = text:find("⚠️", 1, true)

    assert.truthy(heading_at)
    assert.truthy(metrics_at)
    assert.truthy(warning_at)
    -- Reading the cost is the one moment the reader is looking; the warning has to be there,
    -- not in a notification that is gone by the next turn.
    assert.is_true(heading_at < metrics_at)
    assert.is_true(metrics_at < warning_at)
  end)

  it("leaves the warning off while the chat is still small", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage({ _token_usage = usage_of(90000, 4) }, callbacks, {})

    assert.truthy(written(state):find("context 90k", 1, true))
    assert.is_nil(written(state):find("⚠️", 1, true))
  end)

  it("repeats the warning on every turn that stays above the threshold", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage({ _token_usage = usage_of(200000, 8) }, callbacks, {})
    SendMessage._report_token_usage({ _token_usage = usage_of(210000, 8) }, callbacks, {})

    local count = select(2, written(state):gsub("⚠️", ""))
    -- A gauge that shows itself once is one the reader scrolls past; this is not a notification.
    assert.equals(2, count)
  end)

  it("honours a custom threshold", function()
    local state, callbacks = harness()

    SendMessage._report_token_usage(
      { _token_usage = usage_of(90000, 4) },
      callbacks,
      { agent = { token_usage = { warn_context = 80000 } } }
    )

    assert.truthy(written(state):find("⚠️", 1, true))
    assert.truthy(written(state):find("80k", 1, true))
  end)

  describe("configured through setup()", function()
    local Config = require("vibing.config")

    after_each(function()
      Config.setup({})
    end)

    --- The path a user's lazy.nvim block actually takes: setup() merges into the defaults, and
    --- `ChatBuffer:send_message` hands `vibing.get_config()` to the reporter. Asserting against a
    --- hand-built config table would pass even if the key stopped surviving that merge.
    it("carries a raised threshold from setup() to the warning", function()
      Config.setup({ agent = { token_usage = { warn_context = 250000 } } })
      local state, callbacks = harness()

      SendMessage._report_token_usage({ _token_usage = usage_of(200000, 9) }, callbacks, Config.get())

      -- 200k would have warned at the 150k default; the configured 250k must suppress it.
      assert.truthy(written(state):find("context 200k", 1, true))
      assert.is_nil(written(state):find("⚠️", 1, true))
    end)

    it("still warns once the configured threshold is passed", function()
      Config.setup({ agent = { token_usage = { warn_context = 250000 } } })
      local state, callbacks = harness()

      SendMessage._report_token_usage({ _token_usage = usage_of(260000, 9) }, callbacks, Config.get())

      assert.truthy(written(state):find("⚠️", 1, true))
      assert.truthy(written(state):find("250k", 1, true))
    end)

    it("switches the whole section off from setup()", function()
      Config.setup({ agent = { token_usage = { enabled = false } } })
      local state, callbacks = harness()

      SendMessage._report_token_usage({ _token_usage = usage_of(900000, 30) }, callbacks, Config.get())

      assert.equals("", written(state))
    end)

    it("keeps the sibling agent defaults that the merge must not drop", function()
      Config.setup({ agent = { token_usage = { warn_context = 250000 } } })

      -- A shallow merge here would wipe every other agent.* default, which is the failure this
      -- pins: the reporter would still work while unrelated features quietly lost their config.
      assert.equals(250000, Config.get().agent.token_usage.warn_context)
      assert.is_true(Config.get().agent.token_usage.enabled)
      assert.is_true(Config.get().agent.plugins.self)
      assert.equals("sonnet", Config.get().agent.utility_model)
    end)
  end)
end)
