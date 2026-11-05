-- What these pin is the half that fails silently: that the handshake a real CLI needs actually
-- goes out, that NOTHING ELSE does (a probe that sent a prompt would spend tokens on every
-- keystroke-triggered refresh), and that an answer we cannot read resolves to nil -- "ask again" --
-- rather than an empty list that would be cached as "this project has no commands".
--
-- The CLI is a shell script that logs each line it receives and replies from a fixed script, so
-- the order and the content of what the probe wrote are visible to the assertions.

local ROOT = vim.fn.tempname()
vim.fn.mkdir(ROOT, "p")

local LOG = ROOT .. "/received"

---Write an executable that reads one line per step, logs it, and prints that step's replies.
---@param steps string[][] replies printed after reading the Nth line
---@param hold boolean? stay alive after the last step, as a real agent does
---@return string path
local function write_fake_cli(steps, hold)
  local script = { "#!/bin/sh", 'LOG="$1"' }
  for _, replies in ipairs(steps) do
    table.insert(script, 'read -r line; printf "%s\\n" "$line" >> "$LOG"')
    for _, reply in ipairs(replies) do
      table.insert(script, "printf '%s\\n' " .. vim.fn.shellescape(reply))
    end
  end
  if hold then
    table.insert(script, "exec sleep 10")
  end
  local path = ROOT .. "/fake-cli"
  vim.fn.writefile(script, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end

---@return table[] decoded lines the fake CLI received, in order
local function received()
  local lines = {}
  for _, line in ipairs(vim.fn.filereadable(LOG) == 1 and vim.fn.readfile(LOG) or {}) do
    table.insert(lines, vim.json.decode(line))
  end
  return lines
end

---Run a probe's `fetch` and block until it calls back.
---@param module string
---@param steps string[][]
---@param hold boolean? keep the fake CLI alive, so only the probe itself can end the job early
---@return Vibing.CliCommand[]? commands
---@return integer elapsed_ms
local function run(module, steps, hold)
  local done, result = false, nil
  local started_at = vim.uv.hrtime()
  assert.is_true(require(module).fetch({
    argv = { write_fake_cli(steps, hold), LOG },
    cwd = ROOT,
    timeout_ms = 3000,
  }, function(commands)
    result, done = commands, true
  end))
  assert.is_true(vim.wait(5000, function()
    return done
  end, 20))
  return result, (vim.uv.hrtime() - started_at) / 1e6
end

---A refusal must end the job on its own. With the fake CLI exiting afterwards, a probe that
---ignored the error would still return nil -- from the process dying -- and the test could not
---tell the two apart; held open, it can only be the probe's doing, and it is fast.
local function assert_refused_promptly(commands, elapsed)
  assert.is_nil(commands)
  assert.is_true(elapsed < 2000, "the probe waited for the deadline instead of failing: " .. elapsed .. "ms")
end

local INIT_OK = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'

describe("probes.acp", function()
  local ACP = "vibing.infrastructure.completion.probes.acp"

  before_each(function()
    vim.fn.delete(LOG)
  end)

  it("returns what the agent advertises after session/new", function()
    local commands = run(ACP, {
      { INIT_OK },
      {
        '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}',
        '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":'
          .. '{"sessionUpdate":"available_commands_update","availableCommands":'
          .. '[{"name":"loop","description":"Run on an interval"},{"name":"design"}]}}}',
      },
    })

    assert.equals(2, #commands)
    assert.equals("loop", commands[1].name)
  end)

  it("sends the handshake and nothing that could reach the model", function()
    run(ACP, {
      { INIT_OK },
      {
        '{"jsonrpc":"2.0","method":"session/update","params":{"update":'
          .. '{"sessionUpdate":"available_commands_update","availableCommands":[]}}}',
      },
    })

    local sent = received()
    assert.equals(2, #sent)
    assert.equals("initialize", sent[1].method)
    assert.equals("session/new", sent[2].method)
    assert.equals(ROOT, sent[2].params.cwd)
    -- Required by the protocol, and empty so the user's MCP servers are not started for a probe.
    assert.same({}, sent[2].params.mcpServers)
    for _, message in ipairs(sent) do
      assert.not_equals("session/prompt", message.method)
    end
  end)

  it("skips updates that are not the command list", function()
    local commands = run(ACP, {
      { INIT_OK },
      {
        '{"jsonrpc":"2.0","method":"session/update","params":{"update":'
          .. '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}',
        -- Another update kind that happens to carry a `availableCommands` field is not the list.
        '{"jsonrpc":"2.0","method":"session/update","params":{"update":'
          .. '{"sessionUpdate":"plan","availableCommands":[{"name":"decoy"}]}}}',
        '{"jsonrpc":"2.0","method":"session/update","params":{"update":'
          .. '{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"loop"}]}}}',
      },
    })

    assert.equals(1, #commands)
    assert.equals("loop", commands[1].name)
  end)

  it("returns nil when the handshake is refused rather than an empty list", function()
    assert_refused_promptly(run(ACP, {
      { '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"nope"}}' },
    }, true))
  end)

  it("returns nil when session/new fails", function()
    assert_refused_promptly(run(ACP, {
      { INIT_OK },
      { '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params"}}' },
    }, true))
  end)

  it("returns nil when the agent exits without advertising anything", function()
    assert.is_nil((run(ACP, { { INIT_OK } })))
  end)
end)

describe("probes.codex_skills", function()
  local CODEX = "vibing.infrastructure.completion.probes.codex_skills"
  local INIT = '{"id":1,"result":{"userAgent":"codex"}}'

  before_each(function()
    vim.fn.delete(LOG)
  end)

  it("returns the enabled skills with the scope each came from", function()
    local commands = run(CODEX, {
      { INIT },
      {},
      {
        '{"id":2,"result":{"data":[{"cwd":"/x","skills":['
          .. '{"name":"ci-gates","description":"Gates","scope":"repo","enabled":true},'
          .. '{"name":"docx","description":"Word","scope":"user","enabled":true},'
          .. '{"name":"imagegen","description":"Images","scope":"system","enabled":true},'
          .. '{"name":"off","description":"Disabled","scope":"user","enabled":false}]}]}}',
      },
    })

    assert.equals(3, #commands)
    assert.equals("project", commands[1].source)
    assert.equals("user", commands[2].source)
    assert.equals("bundled", commands[3].source)
    assert.equals("Images", commands[3].description)
  end)

  it("asks about the probe's own directory after the initialized notification", function()
    run(CODEX, { { INIT }, {}, { '{"id":2,"result":{"data":[{"skills":[]}]}}' } })

    local sent = received()
    assert.equals(3, #sent)
    assert.equals("initialize", sent[1].method)
    assert.equals("initialized", sent[2].method)
    assert.equals("skills/list", sent[3].method)
    assert.same({ ROOT }, sent[3].params.cwds)
  end)

  it("returns nil for an error response rather than an empty list", function()
    assert_refused_promptly(run(CODEX, { { INIT }, {}, { '{"id":2,"error":{"code":-32601,"message":"unknown"}}' } }, true))
  end)

  it("returns nil when the result has no skills list", function()
    assert_refused_promptly(run(CODEX, { { INIT }, {}, { '{"id":2,"result":{"data":[]}}' } }, true))
  end)

  it("returns nil when initialize is refused", function()
    assert_refused_promptly(run(CODEX, { { '{"id":1,"error":{"code":-32600,"message":"nope"}}' } }, true))
  end)
end)
