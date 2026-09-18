--- The three deadlines an approval sits inside, asserted for **every** registered backend (#778).
---
---   permissions.approval_wait_sec  <  pre-tool-use.sh's own wait  <  <backend>'s hook timeout
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
local Config = require("vibing.config")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local Transports = require("vibing.infrastructure.hooks.transports")
local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")

--- What the shell actually does, read out of the shell. The invariant spans two languages; a copy
--- of the arithmetic in Lua is a copy that can stop matching.
--- @return {fallback_sec: number, ticks_per_sec: number, sleep: number, env_var: string}
local function read_script_deadline()
  local path = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local f = assert(io.open(path, "r"), "could not open pre-tool-use.sh at " .. path)
  local source = f:read("*a")
  f:close()

  local env_var, fallback = source:match('\nMAX_WAIT_SEC="%${([%u_]+):%-(%d+)}"')
  assert(env_var, "could not read MAX_WAIT_SEC's environment variable and fallback out of pre-tool-use.sh")

  local ticks_per_sec = tonumber(source:match("\nMAX_WAIT=%$%(%(MAX_WAIT_SEC %* (%d+)%)%)"))
  assert(ticks_per_sec, "could not read the seconds-to-ticks multiplier out of pre-tool-use.sh")

  local sleep = tonumber(source:match("\n%s*sleep%s+([%d%.]+)"))
  assert(sleep, "could not read the poll loop's sleep out of pre-tool-use.sh")

  return { fallback_sec = tonumber(fallback), ticks_per_sec = ticks_per_sec, sleep = sleep, env_var = env_var }
end

describe("hook timeout ordering", function()
  local script = read_script_deadline()

  describe("the script's own deadline", function()
    it("counts ticks, and the multiplier matches the tick", function()
      -- The unit is the trap. The loop counts 0.1s ticks, so the budget in seconds has to be
      -- multiplied by ten to become a loop bound. Getting this wrong is off by a factor of ten in
      -- whichever direction, and one of those directions silently declares an unsafe configuration
      -- safe while every comparison below still passes.
      assert.equals(
        1 / script.sleep,
        script.ticks_per_sec,
        string.format("the loop sleeps %ss per tick but converts seconds with *%d", tostring(script.sleep), script.ticks_per_sec)
      )
    end)

    it("falls back to less than the smallest timeout any backend can register", function()
      -- The literal in the script is for a hook that runs without our environment — a stale
      -- generated settings file, a CLI that dropped the variable. It cannot be the *default*
      -- derivation: a user who lowers `approval_wait_sec` lowers every registered timeout with it,
      -- and a fallback sized for the default would then outlast them and fail open. So it is
      -- pinned against the floor instead, which holds for every configured value.
      assert.is_true(
        script.fallback_sec < WaitBudget.min_cli_timeout_sec(),
        string.format(
          "the script waits %ss without our environment, but a backend may register a timeout as low as %ss",
          tostring(script.fallback_sec),
          tostring(WaitBudget.min_cli_timeout_sec())
        )
      )
    end)

    it("stays below the smallest timeout even at the configured floor", function()
      -- The end-to-end form of the same thing: set the shortest wait a user can ask for and check
      -- the fallback is still inside what that produces.
      local original = Config.get().permissions.approval_wait_sec
      Config.get().permissions.approval_wait_sec = 1
      local ok, err = pcall(function()
        assert.equals(WaitBudget.MIN_APPROVAL_WAIT_SEC, WaitBudget.approval_wait_sec())
        assert.is_true(script.fallback_sec < WaitBudget.cli_timeout_sec())
        assert.is_true(WaitBudget.script_wait_sec() < WaitBudget.cli_timeout_sec())
      end)
      Config.get().permissions.approval_wait_sec = original
      assert.is_true(ok, tostring(err))
    end)

    it("reads the deadline from the variable the environment binding writes", function()
      assert.equals(WaitBudget.MAX_WAIT_VAR, script.env_var)

      local env = {}
      WaitBudget.bind(env)
      assert.equals(tostring(WaitBudget.script_wait_sec()), env[WaitBudget.MAX_WAIT_VAR])
    end)
  end)

  describe("the derivation", function()
    it("restates config.lua's default rather than owning a second one", function()
      assert.equals(WaitBudget.DEFAULT_APPROVAL_WAIT_SEC, Config.get().permissions.approval_wait_sec)
    end)

    it("keeps all three in order", function()
      assert.is_true(WaitBudget.approval_wait_sec() < WaitBudget.script_wait_sec())
      assert.is_true(WaitBudget.script_wait_sec() < WaitBudget.cli_timeout_sec())
    end)

    it("moves every deadline when the configured wait changes", function()
      -- The point of one source. A user who raises the wait must not end up with a script that
      -- gives up first, nor a CLI timeout that fires before either.
      local original = Config.get().permissions.approval_wait_sec
      Config.get().permissions.approval_wait_sec = 2400
      local ok, err = pcall(function()
        assert.equals(2400, WaitBudget.approval_wait_sec())
        assert.equals(2400 + WaitBudget.SCRIPT_MARGIN_SEC, WaitBudget.script_wait_sec())
        assert.equals(2400 + WaitBudget.SCRIPT_MARGIN_SEC + WaitBudget.CLI_MARGIN_SEC, WaitBudget.cli_timeout_sec())
        for _, def in ipairs(Agents.list()) do
          local descriptor = require(def.descriptor_module)
          if descriptor.hook then
            assert.is_true(
              (Transports.hook_timeout_sec(descriptor.hook) or 0) > WaitBudget.script_wait_sec(),
              def.id .. " did not follow the configured wait upwards"
            )
          end
        end
      end)
      Config.get().permissions.approval_wait_sec = original
      assert.is_true(ok, tostring(err))
    end)

    it("stays inside the CLI's patience for a silent MCP tool", function()
      -- A fourth deadline on a different path. `nvim_ask_user_question` is an MCP tool call rather
      -- than a hook, so it is bounded by how long the CLI will hold a silent MCP tool open —
      -- measured at 1800s on claude — and nothing in the three numbers above knows that. Raising
      -- `approval_wait_sec` past it has to fail here rather than become a silent 30-minute hang.
      assert.is_true(
        WaitBudget.cli_timeout_sec() < WaitBudget.MCP_TOOL_IDLE_TIMEOUT_SEC,
        string.format(
          "the derived budget is %ss against a measured MCP ceiling of %ss",
          tostring(WaitBudget.cli_timeout_sec()),
          tostring(WaitBudget.MCP_TOOL_IDLE_TIMEOUT_SEC)
        )
      )
    end)

    it("fails when a configured wait would outlast that ceiling", function()
      local original = Config.get().permissions.approval_wait_sec
      Config.get().permissions.approval_wait_sec = WaitBudget.MCP_TOOL_IDLE_TIMEOUT_SEC
      local ok = pcall(function()
        assert.is_true(WaitBudget.cli_timeout_sec() < WaitBudget.MCP_TOOL_IDLE_TIMEOUT_SEC)
      end)
      Config.get().permissions.approval_wait_sec = original
      assert.is_false(ok, "a wait at the MCP ceiling must not read as inside it")
    end)

    it("ignores a nonsense configured wait instead of deriving nonsense from it", function()
      local original = Config.get().permissions.approval_wait_sec
      for _, bad in ipairs({ 0, -1, "900" }) do
        Config.get().permissions.approval_wait_sec = bad
        local ok, err = pcall(function()
          assert.equals(WaitBudget.DEFAULT_APPROVAL_WAIT_SEC, WaitBudget.approval_wait_sec())
        end)
        Config.get().permissions.approval_wait_sec = original
        assert.is_true(ok, string.format("approval_wait_sec = %s: %s", tostring(bad), tostring(err)))
      end
    end)
  end)

  describe("which backends may wait for an approval", function()
    it("refuses a backend with no measured floor", function()
      -- The default a new backend inherits by writing nothing. Unmeasured must not read as fine:
      -- past its own timeout every CLI measured fails open, so waiting on a CLI nobody has timed is
      -- a permission gate that stops applying without saying so.
      assert.is_false(Transports.can_wait_for_approval({ transport = "settings_file" }))
      assert.is_false(Transports.can_wait_for_approval(nil))
    end)

    it("refuses a floor that does not cover the script's deadline", function()
      assert.is_false(
        Transports.can_wait_for_approval({ measured_wait_floor_sec = WaitBudget.script_wait_sec() })
      )
      assert.is_true(
        Transports.can_wait_for_approval({ measured_wait_floor_sec = WaitBudget.script_wait_sec() + 1 })
      )
    end)

    it("withdraws a backend whose floor the configured wait has outgrown", function()
      -- Raising `approval_wait_sec` past what a CLI was measured to tolerate must turn the feature
      -- off for that CLI rather than wait longer than the evidence covers. This is the whole reason
      -- the descriptor records a measurement instead of a boolean.
      local claude = require("vibing.infrastructure.adapter.backends.claude")
      assert.is_true(Transports.can_wait_for_approval(claude.hook))

      local original = Config.get().permissions.approval_wait_sec
      Config.get().permissions.approval_wait_sec = claude.hook.measured_wait_floor_sec
      local ok, err = pcall(function()
        assert.is_false(Transports.can_wait_for_approval(claude.hook))
      end)
      Config.get().permissions.approval_wait_sec = original
      assert.is_true(ok, tostring(err))
    end)

    it("matches the floors the handbook records, per backend", function()
      -- Pinned so that adding a number is a deliberate act with a measurement behind it. codex and
      -- grok are unmeasured, and staying unmeasured has to be visible rather than inferred from an
      -- absent field nobody looks at.
      local expected = { claude = true, copilot = true, codex = false, grok = false }
      for _, def in ipairs(Agents.list()) do
        local descriptor = require(def.descriptor_module)
        assert.equals(
          expected[def.id],
          Transports.can_wait_for_approval(descriptor.hook),
          def.id .. " changed whether it may answer an approval in place"
        )
      end
    end)
  end)

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
          -- Against both the derived deadline and the script's env-absent fallback, because a hook
          -- that runs without our environment waits for the latter.
          for _, deadline in ipairs({ WaitBudget.script_wait_sec(), script.fallback_sec }) do
            assert.is_true(
              timeout > deadline,
              string.format(
                "%s registers timeout=%ss against a script deadline of %ss; the CLI must give up "
                  .. "strictly later, or a slow approval becomes an ungated tool call",
                def.id,
                tostring(timeout),
                tostring(deadline)
              )
            )
          end
        end)
      end)
    end
  end
end)
