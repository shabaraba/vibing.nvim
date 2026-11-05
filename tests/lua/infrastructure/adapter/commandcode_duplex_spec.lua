--- The resident Command Code ACP wire. `apply_options` chains model → mode → effort → prompt,
--- each on the previous reply, so these specs pin which `session/set_config_option` frames go out
--- and in what order — the ordering the CLI's "A prompt is already running" error makes a contract
--- rather than a style. Everything here is short of the real CLI: the job is stubbed, the replies
--- are the ones measured against 1.88.2.
local helper = require("tests.helpers.adapter_stream")
local Adapter = require("vibing.infrastructure.adapter.commandcode_cli")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local CHAT = 4244

describe("Command Code duplex ACP", function()
  local jobs, adapter, exepath

  before_each(function()
    jobs = helper.stub_jobstart()
    helper.reset_path_caches()
    exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("duplex-commandcode")
    end
    adapter = Adapter:new({
      ai = {
        chat = { agent = "commandcode", model = "deepseek/deepseek-v4-flash" },
        agents = { commandcode = { process = "duplex" } },
      },
      integrations = { plugins = { self = false, project_dir = false } },
    })
  end)

  after_each(function()
    Pool._reset()
    jobs.restore()
    vim.fn.exepath = exepath
    helper.reset_path_caches()
  end)

  local function send(extra)
    local result = { responses = {} }
    result.turn, result.process = adapter:stream(
      "hello",
      vim.tbl_extend("force", { chat_bufnr = CHAT, permissions_allow = {} }, extra or {}),
      function() end,
      function(response)
        table.insert(result.responses, response)
      end
    )
    return result
  end

  local function frames(call)
    return jobs.sent(call)
  end

  local function last(call)
    return frames(call)[#frames(call)]
  end

  local function reply(call, result)
    jobs.emit(call, { vim.json.encode({ id = last(call).id, result = result }) })
  end

  --- Answer the handshake, opening the session with the options the CLI reports.
  --- @param call table
  --- @param config_options table[] the `configOptions` `session/new` answers with
  local function open_session(call, config_options)
    assert.equals("initialize", last(call).method)
    reply(call, { protocolVersion = 1 })
    assert.equals("session/new", last(call).method)
    reply(call, {
      sessionId = "session-1",
      configOptions = config_options,
      modes = { currentModeId = "default" },
    })
  end

  --- The configOptions of a session on a DeepSeek-shaped default: three effort levels, and none
  --- of them is vibing's `low`.
  local function deepseek_options(effort)
    return {
      { id = "model", currentValue = "deepseek/deepseek-v4-flash" },
      {
        id = "effort",
        currentValue = effort or "high",
        options = { { value = "off" }, { value = "high" }, { value = "max" } },
      },
    }
  end

  --- The configOptions of a session on a Claude-shaped model: vibing's own frontmatter set.
  local function claude_options(effort)
    return {
      { id = "model", currentValue = "claude-sonnet-5-5" },
      {
        id = "effort",
        currentValue = effort,
        options = { { value = "low" }, { value = "medium" }, { value = "high" }, { value = "max" } },
      },
    }
  end

  --- A `session/set_config_option` reply: the whole `configOptions` list, back.
  local function config_result(config_options)
    return { configOptions = config_options }
  end

  --- Complete the open turn, the way the real CLI does: the `session/prompt` reply ends it.
  local function end_turn(call)
    reply(call, { stopReason = "end_turn" })
  end

  --- Every `session/set_config_option` frame written so far, by config id.
  local function config_writes(call)
    return vim.tbl_map(function(frame)
      return frame.params.configId
    end, vim.tbl_filter(function(frame)
      return frame.method == "session/set_config_option"
    end, frames(call)))
  end

  it("offers the bundled vibing-nvim server on session/new", function()
    -- Command Code has no `--plugin-dir`, so the session request is the only route its MCP
    -- servers travel. The CLI connects whatever the client sends here.
    require("vibing.infrastructure.plugins.plugin_dirs").clear_cache()
    local with_plugins = Adapter:new({
      ai = { chat = { agent = "commandcode" }, agents = { commandcode = { process = "duplex" } } },
    })

    with_plugins:stream("hello", { chat_bufnr = CHAT, permissions_allow = {} }, function() end, function() end)
    local call = jobs.only_call()
    assert.equals("initialize", last(call).method)
    reply(call, { protocolVersion = 1 })

    local session_new
    for _, frame in ipairs(frames(call)) do
      if frame.method == "session/new" then
        session_new = frame
      end
    end
    assert.is_not_nil(session_new)
    local by_name = {}
    for _, server in ipairs(session_new.params.mcpServers) do
      by_name[server.name] = server
    end
    local own = by_name["vibing-nvim"]
    assert.is_not_nil(own, "expected the bundled server in " .. vim.inspect(session_new.params.mcpServers))
    assert.equals("sh", own.command)
    assert.is_truthy(table.concat(own.args, " "):find("mcp%-server/bin/run%.sh$"))
  end)

  it("sends only the prompt when the session already reports the wanted options", function()
    send({ model = "deepseek/deepseek-v4-flash", effort = "high" })
    local call = jobs.only_call()
    assert.is_true(vim.tbl_contains(call.argv, "acp"))
    open_session(call, deepseek_options())
    assert.equals("session/prompt", last(call).method)
    assert.same({}, config_writes(call))
  end)

  it("applies a changed effort to the reused process, and remembers it was applied", function()
    local first = send({ model = "deepseek/deepseek-v4-flash", effort = "high" })
    local call = jobs.only_call()
    open_session(call, deepseek_options())
    assert.equals("session/prompt", last(call).method)
    end_turn(call)
    assert.equals(1, #first.responses)

    local second = send({ effort = "max" })
    assert.equals(first.process, second.process)
    assert.equals(1, #jobs.calls)
    assert.equals("session/set_config_option", last(call).method)
    assert.equals("effort", last(call).params.configId)
    assert.equals("max", last(call).params.value)
    reply(call, config_result(deepseek_options("max")))
    assert.equals("session/prompt", last(call).method)
    end_turn(call)
    assert.equals(1, #second.responses)

    -- Same value again: the reply said it is in force, so nothing is re-sent.
    local third = send({ effort = "max" })
    assert.equals(first.process, third.process)
    assert.equals("session/prompt", last(call).method)
    end_turn(call)

    -- `default` resolves to nil and sends nothing, which leaves the session's own effort on it.
    local fourth = send({ effort = "default" })
    assert.equals(first.process, fourth.process)
    assert.equals("session/prompt", last(call).method)
    assert.same({ "effort" }, config_writes(call))
  end)

  it("skips an effort the current model does not offer, and still sends the prompt", function()
    send({ effort = "low" })
    local call = jobs.only_call()
    open_session(call, deepseek_options())
    assert.equals("session/prompt", last(call).method)
    assert.same({}, config_writes(call))
  end)

  it("applies an effort that differs from the session's own on the first turn", function()
    send({ effort = "low" })
    local call = jobs.only_call()
    open_session(call, claude_options("default"))
    assert.equals("session/set_config_option", last(call).method)
    assert.equals("effort", last(call).params.configId)
    assert.equals("low", last(call).params.value)
    reply(call, config_result(claude_options("low")))
    assert.equals("session/prompt", last(call).method)
  end)

  it("re-applies the effort a model switch resets, behind the model request", function()
    send({ model = "claude-sonnet-5-5", effort = "high" })
    local call = jobs.only_call()
    -- The session reports a DeepSeek default, so the model goes first; the chat's effort matches
    -- what the session reports now, and still has to go out once the switch resets it.
    open_session(call, deepseek_options())
    assert.equals("session/set_config_option", last(call).method)
    assert.equals("model", last(call).params.configId)
    reply(call, config_result(claude_options("default")))
    assert.equals("session/set_config_option", last(call).method)
    assert.equals("effort", last(call).params.configId)
    assert.equals("high", last(call).params.value)
    reply(call, config_result(claude_options("high")))
    assert.equals("session/prompt", last(call).method)
    assert.same({ "model", "effort" }, config_writes(call))
  end)
end)
