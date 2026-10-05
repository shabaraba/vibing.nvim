local Decoder = require("vibing.infrastructure.adapter.decoders.codex_app_server")
describe("Codex app-server decoder", function()
  local state
  before_each(function()
    state = {}
  end)
  local function decode(method, params)
    return Decoder.decode({ method = method, params = params }, state)
  end
  it("uses the exec tool contract for command starts and completions", function()
    local item = { id = "shell", type = "commandExecution", command = "ls", aggregatedOutput = "files" }
    local started = decode("item/started", { item = item })
    assert.equals("tool_start", started[1].kind)
    assert.equals("Bash", started[1].name)
    assert.equals("ls", started[1].input.command)
    local done = decode("item/completed", { item = item })
    assert.equals("tool_end", done[1].kind)
    assert.equals("files", done[1].result)
  end)
  it("maps structured file-change kinds and paths", function()
    local events = decode(
      "item/completed",
      {
        item = {
          id = "edit",
          type = "fileChange",
          changes = {
            { path = "main.lua", kind = { type = "update" } },
          },
        },
      }
    )
    assert.same({ "main.lua" }, events[1].input.file_paths)
    assert.equals("modified main.lua", events[2].result)
  end)
  it("maps thread totals to cumulative token usage", function()
    local events = decode(
      "thread/tokenUsage/updated",
      {
        tokenUsage = {
          total = {
            inputTokens = 100,
            cachedInputTokens = 90,
            outputTokens = 12,
            reasoningOutputTokens = 5,
          },
        },
      }
    )
    assert.equals("usage", events[1].kind)
    assert.is_true(require("vibing.core.utils.token_usage").is_cumulative(events[1].accumulator))
  end)
  it("renders message text when the server only emits a completed item", function()
    local events = decode("item/completed", { item = { id = "msg", type = "agentMessage", text = "answer" } })
    assert.equals("answer", events[1].delta)
  end)
  it("keeps the measured hook-trust bypass gap explicit", function()
    local path = vim.fn.getcwd() .. "/tests/fixtures/streams/codex-app-server/hook_trust_probe.json"
    local probe = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.equals("untrusted", probe.session_flag_hooks[1].trustStatus)
  end)
end)
