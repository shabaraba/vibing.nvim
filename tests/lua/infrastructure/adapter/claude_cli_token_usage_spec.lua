--- Wiring test for the seam between the stream and the response: the accumulator is created by
--- `stream()`, filled by the event processor, and has to reach `_handle_response` on the response.
--- Nothing else asserts that last hop, and losing it would leave every turn silently unreported.
describe("claude_cli token usage wiring", function()
  local ClaudeCLI = require("vibing.infrastructure.adapter.claude_cli")
  local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")

  local function assistant_line(write, read, output, parent_tool_use_id)
    return vim.json.encode({
      type = "assistant",
      parent_tool_use_id = parent_tool_use_id or vim.NIL,
      message = {
        role = "assistant",
        content = { { type = "text", text = "ok" } },
        usage = {
          input_tokens = 2,
          cache_creation_input_tokens = write,
          cache_read_input_tokens = read,
          output_tokens = output,
        },
      },
    }) .. "\n"
  end

  --- Runs one turn with the process faked out: the stdout handler is fed the given stream-json
  --- lines, then the exit handler is fired. No CLI is launched and no tokens are spent.
  --- @param lines string[]
  --- @return table response
  local function run_turn(lines)
    local original_spawn = CliRuntime.spawn
    local original_exepath = vim.fn.exepath
    local response = nil

    -- The argv builder resolves the `claude` binary and raises when PATH has none, which sends
    -- the turn down the build-failure path with no stream and no usage. CI installs Neovim and
    -- Lua but not Claude Code, so without this the spec passes on a developer's machine and
    -- fails there -- which is exactly what it did. Any real executable will do: nothing is ever
    -- spawned, because `CliRuntime.spawn` is faked below.
    vim.fn.exepath = function(name)
      if name == "claude" then
        return original_exepath("sh")
      end
      return original_exepath(name)
    end

    CliRuntime.spawn = function(handles, handle_id, _cmd, sys_opts, on_exit, _on_done)
      -- The real spawn registers the handle, and the stdout handler reads its absence as "this
      -- turn was cancelled" and drops every chunk. Without this the stream is silently discarded.
      handles[handle_id] = { pid = -1 }
      for _, line in ipairs(lines) do
        sys_opts.stdout(nil, line)
      end
      -- The stdout handler defers into vim.schedule, so the events have to be drained before the
      -- exit handler builds the response -- the same ordering the real process gives us.
      vim.wait(200, function()
        return false
      end)
      on_exit({ code = 0, signal = 0 })
      return true
    end

    -- `Config.options` is nil until setup() runs, and the command builder indexes it -- which
    -- would send every case here down the build-failure path instead of the stream.
    local Config = require("vibing.config")
    Config.setup({})
    local adapter = ClaudeCLI:new(Config.options)
    local ok, err = pcall(function()
      adapter:stream("hello", { lightweight = true }, function() end, function(res)
        response = res
      end)
    end)

    vim.wait(2000, function()
      return response ~= nil
    end)
    CliRuntime.spawn = original_spawn
    vim.fn.exepath = original_exepath

    assert.is_true(ok, tostring(err))
    assert.is_not_nil(response)
    -- Named explicitly so a future build failure reports itself rather than surfacing three
    -- assertions down as "attempt to index field '_token_usage' (a nil value)".
    assert.is_nil(response.error, "the turn did not reach the stream: " .. tostring(response.error))
    return response
  end

  it("carries the turn's accumulated usage on the response", function()
    local response = run_turn({
      assistant_line(7537, 116639, 877),
      assistant_line(106496, 20406, 491),
    })

    local usage = response._token_usage
    assert.is_not_nil(usage)
    assert.equals(2, usage.requests)
    assert.equals(126904, usage.context)
    assert.equals(137045, usage.read)
    assert.equals(114033, usage.write)
  end)

  it("produces a response the reporter can render", function()
    local response = run_turn({ assistant_line(12000, 205000, 900) })

    local line = require("vibing.core.utils.token_usage").format(response._token_usage)
    assert.truthy(line)
    assert.truthy(line:find("context 217k", 1, true))
    assert.truthy(line:find("1 request", 1, true))
  end)

  it("keeps a subagent's requests out of the context gauge end to end", function()
    local response = run_turn({
      assistant_line(0, 200000, 10),
      assistant_line(0, 80000, 10, "toolu_sub_1"),
    })

    assert.equals(1, response._token_usage.requests)
    assert.equals(1, response._token_usage.subagent_requests)
    assert.equals(200002, response._token_usage.context)
  end)

  it("counts both turns when one process emits two result events", function()
    -- `SendMessage` resumes a subagent in the background, so one request can produce two `result`
    -- events in a single CLI process (architecture.md → "Subagent Chat"). Both turns' requests
    -- were paid for, so both belong in the totals -- and neither may be counted twice.
    local response = run_turn({
      assistant_line(5000, 100000, 200),
      vim.json.encode({ type = "result", subtype = "success" }) .. "\n",
      assistant_line(800, 106000, 150),
      vim.json.encode({ type = "result", subtype = "success" }) .. "\n",
    })

    assert.equals(2, response._token_usage.requests)
    assert.equals(206000, response._token_usage.read)
    assert.equals(5800, response._token_usage.write)
    assert.equals(106802, response._token_usage.context)
  end)

  it("still answers for a turn whose stream carried no usage at all", function()
    local response = run_turn({ vim.json.encode({ type = "result", subtype = "success" }) .. "\n" })

    assert.is_not_nil(response._token_usage)
    assert.equals(0, response._token_usage.requests)
    assert.is_nil(require("vibing.core.utils.token_usage").format(response._token_usage))
  end)
end)
