--- The three timeouts an approval has to sit inside, derived from one number (#778).
---
--- Answering a tool approval without killing the CLI means the PreToolUse hook blocks until the
--- human answers. Three different processes, in three different languages, each have their own
--- idea of how long that may take, and they must stay in this order:
---
---   permissions.approval_wait_sec  <  pre-tool-use.sh MAX_WAIT  <  <backend>'s hook timeout
---
--- **Both CLIs measured fail OPEN when their own hook timeout expires** — the tool runs with no
--- verdict at all (`handbook/architecture/approval-without-kill.md` → "What expiry does"). So the
--- ordering is not tidiness: the last inequality is the only thing standing between a slow human
--- and an ungated tool call. It is made unreachable twice over — vibing's own limit expires first
--- and writes a deny, and if that never happens the script reaches MAX_WAIT and denies on its own
--- — but both of those are *inside* the CLI's timeout only because these numbers say so.
---
--- Hence one source. Three literals in three files drift: `settings_generator.lua` shipped
--- `timeout = 120` against the script's own 120s, equal, with no margin at all.
---
--- **One value, for every backend.** The measured ceilings differ (claude 1080s, copilot 950s) but
--- they are floors of how long each run happened to be watched, not a difference between the CLIs.
--- Deriving a per-backend limit from them would bake a measurement artifact into the product. What
--- the floors decide is a different question — whether the waiting behaviour may be enabled for a
--- backend at all — and that lives with the backend, not here.
--- @module vibing.infrastructure.hooks.wait_budget

local M = {}

--- What the script adds to vibing's own limit.
---
--- Not a second policy. The script's deadline is the backstop for "Neovim answered the RPC and
--- then never wrote a `.res`" — our own bug, or a timer that was never armed. It is deliberately
--- small because the ordinary dead-Neovim cases never reach it: `nc -w 1` failing to connect is
--- already an immediate fail-closed, and a Neovim that exits takes its CLI children with it. So
--- this only has to cover the gap between the fallback timer firing and its write landing.
M.SCRIPT_MARGIN_SEC = 30

--- What a backend's configured hook timeout adds to the script's deadline.
---
--- Covers everything that happens before the poll loop starts counting: process spawn, `cat` of
--- stdin, the `nc -w 1` round trip, and the 0.1s polling granularity. Larger than
--- SCRIPT_MARGIN_SEC because being wrong here fails *open*, where being wrong there fails closed.
M.CLI_MARGIN_SEC = 60

--- The name the script reads its deadline out of. Travels in the CLI child's environment next to
--- `VIBING_NVIM_RPC_PORT` (`adapter/modules/rpc_environment.lua`), because the script is a fixed
--- file on disk shared by every chat and cannot be regenerated per turn.
M.MAX_WAIT_VAR = "VIBING_HOOK_MAX_WAIT_SEC"

--- The default `permissions.approval_wait_sec`.
---
--- Restated rather than owned: `config.lua` is where a default belongs, and this module sits in
--- `infrastructure/`, so requiring config from there and not the other way round is what keeps the
--- dependency one-way. This copy is the floor for a caller that has no config at all — a generator
--- running before `setup()`. `wait_budget_spec.lua` asserts the two are equal, so the restatement
--- fails the build instead of quietly answering 900 where the user configured something else.
---
--- **900 seconds is not derived from the measured ceilings.** They are floors of how long each run
--- happened to be watched (claude 1080s, copilot 950s), so they say the choice is *possible*, not
--- that it is right. What sizes it is what the limit is for: "the user stepped away and is coming
--- back". Half-day absences are the fallback's job, and the fallback is byte-for-byte today's
--- behaviour. Every second beyond that is paid for — the prompt cache TTL is 55/60 minutes and a
--- resident process holds ~200MB of RSS for the duration.
--- `handbook/architecture/approval-without-kill.md` → "Where 900 seconds comes from".
M.DEFAULT_APPROVAL_WAIT_SEC = 900

--- The shortest wait a user may configure.
---
--- A floor, not a preference: it is what makes the script's env-absent fallback safe. That
--- fallback has to stay below the smallest `cli_timeout_sec()` this module can produce, and
--- without a floor here that smallest value has no lower bound. A value under this is raised to
--- it rather than refused — the feature degrading to "asks, then gives up quickly" is the correct
--- reading of a very small number, where erroring would break a chat over a config typo.
M.MIN_APPROVAL_WAIT_SEC = 30

--- How long vibing.nvim itself will hold an approval prompt open before giving up and denying.
--- @return number seconds
function M.approval_wait_sec()
  local ok, Config = pcall(require, "vibing.config")
  if not ok then
    return M.DEFAULT_APPROVAL_WAIT_SEC
  end
  local config = Config.get() or {}
  local value = (config.permissions or {}).approval_wait_sec
  if type(value) ~= "number" or value <= 0 then
    return M.DEFAULT_APPROVAL_WAIT_SEC
  end
  return math.max(M.MIN_APPROVAL_WAIT_SEC, math.floor(value))
end

--- The deadline `bin/hooks/pre-tool-use.sh` polls to.
--- @return number seconds
function M.script_wait_sec()
  return M.approval_wait_sec() + M.SCRIPT_MARGIN_SEC
end

--- What every backend registers as its own hook timeout.
--- @return number seconds
function M.cli_timeout_sec()
  return M.script_wait_sec() + M.CLI_MARGIN_SEC
end

--- The smallest timeout any backend can end up registering, given the floor above. The script's
--- env-absent fallback has to stay strictly below this; `hook_timeout_ordering_spec.lua` reads the
--- shell literal and asserts exactly that.
--- @return number seconds
function M.min_cli_timeout_sec()
  return M.MIN_APPROVAL_WAIT_SEC + M.SCRIPT_MARGIN_SEC + M.CLI_MARGIN_SEC
end

--- A **fourth** deadline, belonging to a different path, and the one thing that bounds this whole
--- derivation from above.
---
--- `nvim_ask_user_question` is an MCP tool call, not a PreToolUse hook, so none of the three
--- numbers above apply to it — the CLI's own patience for a silent MCP tool does. Measured against
--- claude by holding a stub server open until it gave up: *"MCP server "probe" tool "wait_forever"
--- sent no response or progress for 1800s; aborting."* codex and grok are not measured.
---
--- It is recorded rather than configured because raising it is not actually available to us: the
--- same message suggests a per-server `timeout`, but that is **the CLI describing itself, not a
--- measurement**, and `cli_mcp_config.spec()` carries no such field and emits nothing at all on the
--- default path. So this is a ceiling to stay under, which the default comfortably does (990 of
--- 1800). What it buys is that raising `approval_wait_sec` past it fails the suite instead of
--- turning into a silent 30-minute hang. `handbook/architecture/approval-without-kill.md`.
M.MCP_TOOL_IDLE_TIMEOUT_SEC = 1800

--- The environment entry the hook script reads. Merged into the CLI child's environment.
--- @param env table<string, string>
function M.bind(env)
  env[M.MAX_WAIT_VAR] = tostring(M.script_wait_sec())
end

return M
