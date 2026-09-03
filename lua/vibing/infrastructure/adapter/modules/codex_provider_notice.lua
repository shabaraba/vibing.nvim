--- Tells the user, once, that codex's lightweight calls are not reaching their configured
--- provider.
---
--- `codex_command_builder` runs lightweight calls (title generation, `/summarize`, daily summary)
--- with `--ignore-user-config`, which is the only thing that actually keeps them out of the user's
--- MCP servers (#574). It also drops `model_provider`, so a user on a custom provider has those
--- calls silently retargeted at codex's default OpenAI endpoint -- unexpected billing for some, a
--- wordless 401 for anyone pointed at a local provider (#587).
---
--- The warning is not derived from the config file: `codex doctor --json` resolves it for us. That
--- is what makes it worth shipping at all -- a regex over `config.toml` misses a provider set
--- through a profile and matches one in an inactive section, and a warning that is wrong in either
--- direction is worse than none, because its silence reads as "you are fine". The rest of the
--- reasoning, including why the provider is announced rather than restored, is in
--- `handbook/architecture/lightweight-calls.md`.
---
--- @module vibing.infrastructure.adapter.modules.codex_provider_notice

local Notify = require("vibing.core.utils.notify")

local M = {}

--- codex's own default. A user who names it explicitly loses nothing, so they hear nothing.
local DEFAULT_PROVIDER = "openai"

--- The probe is diagnostic and nothing waits for it, so it can afford to give up rather than
--- linger. Measured at 0.2-0.5s against codex 0.147, but `doctor` also probes the active
--- provider's endpoint for reachability, and an unreachable local provider -- exactly the case
--- this warning exists for -- is the one that can sit here.
local PROBE_TIMEOUT_MS = 10000

local probed = false

--- Forget that the probe ran. Test seam only -- the flag is process-wide by design.
function M._reset()
  probed = false
end

--- The resolved provider name from a `codex doctor --json` report, or nil if it cannot be read.
---
--- Every failure is nil rather than a guess. `doctor` exits non-zero on any unrelated failing
--- check -- a missing login alone is enough, so it exits 1 even on a config that loaded cleanly --
--- which is why the caller ignores the exit status and only `checks["config.load"].status`
--- decides.
---
--- The key really is `"model provider"`, with a space, captured from codex 0.147 rather than read
--- off a schema (`tests/fixtures/codex_doctor.json`). If a future codex renames it this returns
--- nil and the warning goes quiet, which is the safe direction to degrade in.
---
--- @param stdout string|nil
--- @return string|nil
function M.parse_provider(stdout)
  local ok, report = pcall(vim.json.decode, stdout)
  if not ok or type(report) ~= "table" then
    return nil
  end

  local check = vim.tbl_get(report, "checks", "config.load")
  if type(check) ~= "table" or check.status ~= "ok" then
    return nil
  end

  local provider = vim.tbl_get(check, "details", "model provider")
  return (type(provider) == "string" and provider ~= "") and provider or nil
end

--- Warn once per Neovim session if lightweight codex calls are leaving the configured provider.
---
--- Runs `codex doctor --json` asynchronously and returns immediately: the call it describes must
--- not wait on a diagnostic. `doctor` has no flag to run one check in isolation (verified against
--- 0.147 -- its only options are `--json`, `--summary`, `--all`, `-c` and formatting), so the
--- reachability request it makes comes with it. That is why this fires on the first lightweight
--- call rather than at `setup()`: a user who never generates a title never pays for it.
---
--- @param codex_path string resolved codex binary (argv[1] of the command already built)
--- @param cwd string? the directory the described call runs in, so both resolve the same config
function M.check(codex_path, cwd)
  if probed then
    return
  end
  probed = true

  local on_exit = function(result)
    local provider = M.parse_provider(result.stdout)
    if not provider or provider == DEFAULT_PROVIDER then
      return
    end

    vim.schedule(function()
      -- %s with explicit quotes, not %q: %q escapes for Lua to read back, so a provider name
      -- carrying a quote or a control character would reach the user as `\"` or a Lua newline
      -- escape. The name comes from the user's own config.toml and is only ever displayed.
      Notify.warn(
        string.format(
          "lightweight calls (chat title, /summarize, daily summary) run with "
            .. "--ignore-user-config to keep them out of your MCP servers, which also drops "
            .. 'model_provider -- so they go to the default "%s" provider, not the configured '
            .. '"%s". Ordinary chat is unaffected.',
          DEFAULT_PROVIDER,
          provider
        ),
        "codex"
      )
    end)
  end

  -- No `env`, deliberately, where the `codex exec` call it describes passes `vim.fn.environ()`
  -- plus the VIBING_* variables. Inheriting is the same environment minus those, and those exist
  -- to tell a *stream* which chat and RPC port it belongs to -- a probe that reads config and
  -- talks to nobody has no use for them. What both must agree on is what selects the config
  -- (CODEX_HOME, PATH, cwd), and inheriting is what keeps that true by construction. If a future
  -- change starts overriding one of those on the exec call, this has to follow.
  --
  -- pcall because a spawn failure here must not take the lightweight call down with it; the
  -- binary resolved a moment ago, so this is the narrow window in which it stopped existing.
  pcall(
    vim.system,
    { codex_path, "doctor", "--json" },
    { text = true, cwd = cwd, timeout = PROBE_TIMEOUT_MS },
    on_exit
  )
end

return M
