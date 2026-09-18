--- Measure send -> first stream event, oneshot against duplex, at real project scale (#777).
---
--- Run with:
---   nvim --headless -u tests/minimal_init.lua -l tests/perf/duplex_latency.lua
---
--- **This spends real tokens.** It is not part of `npm test` and never will be; it exists because
--- the completion condition for the resident transport is a measured number, and a number taken
--- against a toy config would not be one. So it runs the adapter exactly as a chat does — plugin
--- directories, the MCP server, the project's CLAUDE.md, the same system prompt — and changes one
--- thing between the two runs: `backends.claude.process`.
---
--- Three things are measured, because all three are decisions this feature cannot make from a
--- guess:
---
--- 1. **Time to the first stdout line**, not to the first text chunk. A turn's first line is the
---    `system`/`init` event, and that is the latency a resident process is meant to remove.
--- 2. **Whether the CLI reports usage per turn or per session.** If `result` carried a cumulative
---    total and anything accumulated it, every turn after the first would over-report its cost.
---    The per-turn numbers under each transport answer this by comparison.
--- 3. **How long an interrupt takes to actually stop a turn**, which is where
---    `duplex_routing.INTERRUPT_GRACE_MS` comes from.

-- The same shape as `helper.should_run()` guarding the E2E specs, and for the same reason. Today
-- this file is out of `test:lua`'s reach only because plenary collects `*_spec.lua` and this is not
-- one -- but `test:lua` sweeps the whole of `tests/`, so a rename is all it would take to make
-- `npm test` spend real money unattended. The guard is what makes that impossible rather than
-- unlikely.
if os.getenv("VIBING_PERF") ~= "1" then
  print("tests/perf/duplex_latency.lua spends real tokens; set VIBING_PERF=1 to run it.")
  return
end

local TURNS = tonumber(os.getenv("VIBING_PERF_TURNS") or "3")
local PROMPT = "Reply with exactly the word OK and nothing else."
--- Long enough that there is a live turn to interrupt when the interrupt is sent.
local INTERRUPT_PROMPT = "Count slowly from 1 to 100, one number per line, with a short comment on each."

local Config = require("vibing.config")
local Agents = require("vibing.core.constants.agents")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")

--- @param ms number
--- @return string
local function fmt(ms)
  return ms >= 0 and string.format("%.0fms", ms) or "n/a"
end

--- @param usage table|nil
--- @return string
local function usage_line(usage)
  if not usage then
    return "no usage reported"
  end
  return string.format(
    "requests=%s context=%s read=%s write=%s",
    tostring(usage.requests),
    tostring(usage.context),
    tostring(usage.read),
    tostring(usage.write)
  )
end

--- @class Vibing.Perf.Turn
--- @field first_event_ms number
--- @field total_ms number
--- @field usage table|nil what vibing.nvim accumulated for this turn
--- @field result_usage table|nil what the CLI's own `result` line carried, which the decoder ignores
--- @field session_id string|nil
--- @field error string|nil

--- One turn, timed from the `stream()` call to the first stdout line the decoder sees.
--- @param adapter table
--- @param descriptor table
--- @param session_id string|nil
--- @param opts { prompt: string?, interrupt_after_first_event: boolean? }
--- @return Vibing.Perf.Turn
local function timed_turn(adapter, descriptor, session_id, opts)
  opts = opts or {}
  local processor = descriptor.event_processor
  local original = processor.processLine
  local started = vim.uv.hrtime()
  local first_line_at, result_usage, interrupt_at = nil, nil, nil

  local process_id = nil
  processor.processLine = function(line, context)
    first_line_at = first_line_at or vim.uv.hrtime()
    -- Read straight off the wire: the decoder deliberately does not carry `result.usage` anywhere,
    -- so this is the only way to see whether the CLI puts a session total there.
    local ok, msg = pcall(vim.json.decode, line)
    if ok and type(msg) == "table" and msg.type == "result" and type(msg.usage) == "table" then
      result_usage = msg.usage
    end
    if opts.interrupt_after_first_event and not interrupt_at and process_id then
      interrupt_at = vim.uv.hrtime()
      adapter:stop_turn(process_id)
    end
    return original(line, context)
  end

  local done, response = false, nil
  local _, id = adapter:stream(opts.prompt or PROMPT, {
    chat_bufnr = 1,
    cwd = vim.fn.getcwd(),
    permissions_allow = {},
    permission_mode = "default",
    _session_id = session_id,
  }, function() end, function(res)
    response = res
    done = true
  end)
  process_id = id

  vim.wait(180000, function()
    return done
  end, 50)
  local ended = vim.uv.hrtime()
  processor.processLine = original

  if not done then
    adapter:cancel(process_id)
    return { first_event_ms = -1, total_ms = -1, error = "timed out", session_id = session_id }
  end

  return {
    first_event_ms = first_line_at and (first_line_at - started) / 1e6 or -1,
    total_ms = (ended - started) / 1e6,
    interrupt_ms = interrupt_at and (ended - interrupt_at) / 1e6 or nil,
    usage = response and response._token_usage or nil,
    result_usage = result_usage,
    session_id = adapter:get_session_id(process_id) or session_id,
    error = response and response.error or nil,
  }
end

--- @param process string "oneshot" | "duplex"
--- @return Vibing.Perf.Turn[]
local function run(process)
  Config.setup({ agent = { default_model = "sonnet" }, backends = { claude = { process = process } } })
  local descriptor = require(Agents.get("claude").descriptor_module)
  local Adapter = require(Agents.get("claude").adapter_module)
  local adapter = Adapter:new(Config.get())

  local results, session_id = {}, nil
  for turn = 1, TURNS do
    local result = timed_turn(adapter, descriptor, session_id)
    session_id = result.session_id
    table.insert(results, result)
    print(
      string.format(
        "  %s turn %d: first event %s, total %s%s",
        process,
        turn,
        fmt(result.first_event_ms),
        fmt(result.total_ms),
        result.error and ("  ERROR: " .. result.error) or ""
      )
    )
    print(string.format("      vibing usage: %s", usage_line(result.usage)))
    print(string.format("      result.usage on the wire: %s", result.result_usage and vim.inspect(result.result_usage):gsub("%s+", " ") or "absent"))
  end

  if process == "duplex" then
    local interrupted = timed_turn(adapter, descriptor, session_id, {
      prompt = INTERRUPT_PROMPT,
      interrupt_after_first_event = true,
    })
    print(string.format("  duplex interrupt: turn ended %s after the interrupt was sent", fmt(interrupted.interrupt_ms or -1)))
    local after = timed_turn(adapter, descriptor, interrupted.session_id or session_id)
    print(string.format("  duplex turn after the interrupt: first event %s%s", fmt(after.first_event_ms), after.error and ("  ERROR: " .. after.error) or ""))
    table.insert(results, interrupted)
    table.insert(results, after)
  end

  adapter:cancel()
  Pool.stop_all()
  return results
end

print(string.format("claude %s, %d turns per transport, cwd %s", (vim.fn.system("claude --version"):gsub("%s+$", "")), TURNS, vim.fn.getcwd()))
local oneshot = run("oneshot")
local duplex = run("duplex")

print("")
print("| turn | oneshot first event | duplex first event |")
print("| ---- | ------------------- | ------------------ |")
for i = 1, TURNS do
  print(string.format("| %d | %s | %s |", i, fmt(oneshot[i].first_event_ms), fmt(duplex[i].first_event_ms)))
end
vim.cmd("qall!")
