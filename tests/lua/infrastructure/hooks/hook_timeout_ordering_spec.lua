--- The three deadlines an approval sits inside, asserted for **every** registered backend (#778).
---
---   permissions.approval_wait_sec  <  pre-tool-use.sh MAX_WAIT  <  <backend>'s hook timeout
---
--- Why this is a correctness test and not a tidiness one: measured against claude 2.1.236 and
--- copilot 1.0.85, a PreToolUse hook that outlives the **CLI's own** configured timeout is ignored
--- and the tool runs with no verdict at all — fail open. The script's own expiry, by contrast,
--- exits 2 and fails closed. So the last inequality is the only thing keeping a slow permission
--- check from becoming an ungated tool call, and it has to hold on every backend, not on the one
--- whose generator happened to be written with it in mind.
---
--- It was checked for copilot alone. Claude therefore shipped `timeout = 120` against the script's
--- own 120 seconds — equal, no margin — for as long as that spec was the only one.
local Agents = require("vibing.core.constants.agents")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local Transports = require("vibing.infrastructure.hooks.transports")

--- The script's own deadline, read out of the shell rather than restated here. The invariant spans
--- two languages; a copy of the number in Lua is a copy that can stop matching.
--- @return number ticks
--- @return number seconds_per_tick
local function read_script_deadline()
  local path = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local f = assert(io.open(path, "r"), "could not open pre-tool-use.sh at " .. path)
  local source = f:read("*a")
  f:close()

  local ticks = tonumber(source:match("\nMAX_WAIT=%${?[%u_]*:%-?(%d+)}?") or source:match("\nMAX_WAIT=(%d+)"))
  assert(ticks, "could not read MAX_WAIT out of pre-tool-use.sh")

  local sleep = tonumber(source:match("\n%s*sleep%s+([%d%.]+)"))
  assert(sleep, "could not read the poll loop's sleep out of pre-tool-use.sh")

  return ticks, sleep
end

describe("hook timeout ordering", function()
  it("reads MAX_WAIT as ticks, not seconds", function()
    -- The unit is the trap. `MAX_WAIT=1200` is 120 seconds, because the loop sleeps 0.1s and adds
    -- 1 per pass. Reading it as seconds makes every comparison below off by a factor of ten, in
    -- the direction that silently declares an unsafe configuration safe.
    local ticks, sleep = read_script_deadline()
    assert.equals(0.1, sleep, "the poll loop's tick is what converts MAX_WAIT to seconds")

    local source_line = string.format("MAX_WAIT=%d at %.1fs per tick", ticks, sleep)
    assert.is_true(ticks % 10 == 0, source_line .. " is not a whole number of seconds")
  end)

  local script_ticks, seconds_per_tick = read_script_deadline()
  local script_wait_sec = script_ticks * seconds_per_tick

  for _, def in ipairs(Agents.list()) do
    local descriptor = require(def.descriptor_module)

    if descriptor.hook then
      describe(def.id, function()
        it("declares a PreToolUse timeout its transport can report", function()
          -- A transport that answers nil is not "no timeout" — it is a generator whose schema this
          -- check cannot see into, which is indistinguishable from an unsafe one. Fail rather than
          -- skip: skipping is how copilot ended up being the only backend covered.
          local timeout = Transports.hook_timeout_sec(descriptor.hook)
          assert.is_number(
            timeout,
            string.format(
              "%s's transport %q reports no hook timeout, so the fail-open ordering cannot be checked for it",
              def.id,
              tostring(descriptor.hook.transport)
            )
          )
        end)

        it("gives the hook script time to fail closed before the CLI fails open", function()
          local timeout = Transports.hook_timeout_sec(descriptor.hook)
          assert.is_true(
            timeout > script_wait_sec,
            string.format(
              "%s registers timeout=%ss against pre-tool-use.sh's own %ss deadline; the CLI must "
                .. "give up strictly later, or a slow approval becomes an ungated tool call",
              def.id,
              tostring(timeout),
              tostring(script_wait_sec)
            )
          )
        end)
      end)
    end
  end
end)
