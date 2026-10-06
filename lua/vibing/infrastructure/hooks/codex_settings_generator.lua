--- Codex hook settings generator
---
--- Codex has no per-run hook file, so the hook goes in as a `-c` override -- but the script it
--- points at has to be staged inside the working directory first. See `ensure()`.
--- @module vibing.infrastructure.hooks.codex_settings_generator

local Fs = require("vibing.core.utils.fs")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

local M = {}

--- Codex's hook timeout, in seconds.
---
--- Stays above the deadline pre-tool-use.sh gives itself for the same reason copilot's does:
--- whichever side gives up first decides, and the script's deny is the only one that carries a
--- reason. Both are derived from `permissions.approval_wait_sec` (`wait_budget.lua`), which is what
--- makes that ordering a property rather than a coincidence.
---
--- What this transport registers as its PreToolUse timeout. See
--- `settings_generator.hook_timeout_sec` for why every transport answers this.
--- @return number|nil seconds
function M.hook_timeout_sec()
  return require("vibing.infrastructure.hooks.wait_budget").cli_timeout_sec()
end

--- The `-c` config key. **PascalCase, and that is load-bearing.**
---
--- Codex 0.153 reads `hooks.<PascalCaseEvent>` and silently ignores anything else -- no warning, no
--- error, no entry in `hooks/list`. vibing.nvim shipped `hooks.pre_tool_use` (snake_case) with a
--- flat handler list, which parsed as TOML and was then dropped on the floor, so **no PreToolUse
--- hook fired on codex at all**: no permission gate, and no git-snapshot baseline, which took the
--- per-request diff and every `.vibing/patches/*.patch` with it.
---
--- Verified against codex 0.153.4 by asking the app-server for the hooks it actually resolved
--- (`handbook/architecture/cli-integration.md` has the runnable form). `hooks/list` is the cheap
--- oracle here: it resolves the same config the agent would, reports `warnings`/`errors`, and
--- spends no tokens.
local HOOK_EVENT_KEY = "hooks.PreToolUse"

--- Codex will not run a hook it has not been told to trust.
---
--- Every hook is reported enabled but `untrusted` until the user reviews it in the TUI, which
--- persists a `trusted_hash` into their real `config.toml`. A `-c` layer cannot grant its own trust
--- -- `hooks.state.<key>.trusted_hash` passed as a session flag leaves it `untrusted` (measured),
--- which is the right call on codex's part, since otherwise the flag would defeat the mechanism.
---
--- That leaves this flag as the only way for a headless `codex exec` to run the hook, and it is
--- **not optional**: with the hook registered and untrusted, `codex exec` blocks waiting for a
--- review that has no terminal to happen in (measured: no output, no tool call, killed at 180s).
--- So the flag is returned together with the hook rather than as a separate option -- passing one
--- without the other either does nothing (old key) or hangs the turn (new key).
---
--- The cost, stated honestly: for this one invocation it also un-gates the user's own
--- `~/.codex/hooks.json` entries that they have added but never reviewed. Hooks they *have*
--- reviewed are already trusted and unaffected.
local TRUST_FLAG = "--dangerously-bypass-hook-trust"

--- Where the staged copy of the hook script lives, for a given cwd.
---
--- Resolved, so this reports the same path `ensure()` writes: that one resolves the cwd, and a
--- symlinked working directory would otherwise make the two disagree. Same reasoning as
--- `copilot_settings_generator.plugin_dir`.
--- @param cwd string
--- @return string
function M.script_path(cwd)
  return vim.fn.resolve(cwd) .. "/.vibing/codex-pre-tool-use.sh"
end

--- Only reuse an actual copy with the exact permissions staging installs.
--- @param path string
--- @param contents string
--- @return boolean
local function staged_matches(path, contents)
  local stat = vim.loop.fs_lstat(path)
  -- lstat excludes links outside the writable roots. The low twelve bits include special bits.
  if not stat or stat.type ~= "file" or stat.mode % 4096 ~= tonumber("755", 8) then
    return false
  end
  local staged = io.open(path, "rb")
  if not staged then
    return false
  end
  local staged_contents = staged:read("*a")
  staged:close()
  return staged_contents == contents
end

--- Stage the hook script inside the working directory and return its path.
---
--- **Codex will not execute a hook script that lives outside the sandbox's writable roots**
--- (`workdir`, `/tmp`, `$TMPDIR` -- codex prints them in its own startup banner), and it does not
--- report that as an error: the turn hangs exactly the way an untrusted hook does. vibing.nvim's
--- script lives in the installed plugin directory, which is outside the user's project by
--- definition, so pointing `-c` straight at it hangs every codex turn.
---
--- Measured against codex 0.153.4 with `--sandbox workspace-write` (what `codex_command_builder`
--- passes for every mode but `plan`/`bypassPermissions`), same script, same argv, only the path
--- moved:
---
---     <plugin>/bin/hooks/pre-tool-use.sh   -> hook never ran, turn hung (killed at 180s)
---     /tmp/pre-tool-use.sh                 -> fired, full RPC round trip
---     <cwd>/.vibing/pre-tool-use.sh        -> fired, full RPC round trip
---
--- The last one is what this does. `/tmp` also works but is machine-wide shared state, where
--- `<cwd>/.vibing/` is already this plugin's own scratch directory, is git-ignored, and is where
--- copilot's throwaway plugin goes for the same reason. A symlink is not used: it would point back
--- out of the writable roots, which is the case that fails.
---
--- The source is read on every call so updates and reinstalls cannot leave stale hook logic.
--- An identical copy with permissions 0755 is reused; otherwise the write goes through a temp file
--- and a rename because chats share this path. A reader catching a truncated script would get a
--- hook that fails in a way none of the three decisions covers. `rename(2)` is atomic within a
--- directory. One shared path is safe because the contents are identical for every chat:
--- per-process identity (`VIBING_PROCESS_ID`, the RPC port) travels in codex's environment.
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @return string path Absolute path to the staged script
function M.ensure(cwd)
  local path = M.script_path(cwd or vim.fn.getcwd())
  Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))

  local source = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local src, src_err = io.open(source, "rb")
  if not src then
    error("Failed to read the hook script: " .. source .. " (" .. tostring(src_err) .. ")")
  end
  local contents = src:read("*a")
  src:close()

  if staged_matches(path, contents) then
    return path
  end

  local tmp_path = string.format("%s.%d.tmp", path, vim.loop.getpid())
  local out, out_err = io.open(tmp_path, "wb")
  if not out then
    error("Failed to stage the codex hook script: " .. tmp_path .. " (" .. tostring(out_err) .. ")")
  end
  out:write(contents)
  out:close()

  -- Before the rename, so the script is never visible at its final path without the bit set.
  -- setfperm keeps this synchronous without spawning a second process. Besides being cheaper,
  -- that matters during adapter setup: every `vim.system` call there is an observable CLI launch
  -- in the stream lifecycle and in its tests.
  if vim.fn.setfperm(tmp_path, "rwxr-xr-x") ~= 1 then
    os.remove(tmp_path)
    error("Failed to make the staged codex hook script executable: " .. tmp_path)
  end

  local ok, rename_err = os.rename(tmp_path, path)
  if not ok then
    os.remove(tmp_path)
    error("Failed to install the codex hook script: " .. path .. " (" .. tostring(rename_err) .. ")")
  end

  return path
end

--- Flags for injecting the PreToolUse hook into `codex exec`
---
--- Raises if the script cannot be staged, which is why `codex_cli.lua` calls this under `pcall`:
--- registering the hook without a script codex can run is the one outcome to avoid, since that is
--- the shape that hangs rather than the one that merely skips the gate.
--- @param cwd? string Working directory the codex process will run in
--- @param dialect? string how the script should phrase its decision (`hooks/transports.lua`)
--- @return string[] argv fragment: {"--dangerously-bypass-hook-trust", "-c", "hooks.PreToolUse=[...]"}
function M.get_hook_args(cwd, dialect)
  local script = SettingsGenerator.hook_command(M.ensure(cwd), dialect)
  local escaped = script:gsub("\\", "\\\\"):gsub('"', '\\"')
  return {
    TRUST_FLAG,
    "-c",
    string.format(
      -- A matcher group (`{hooks=[...]}`) wrapping `type`-tagged handlers. The handler cannot sit
      -- at the top level: codex parses `[{command=...}]` as a group with no handlers and resolves
      -- nothing.
      '%s=[{hooks=[{type="command",command="%s",timeout=%d}]}]',
      HOOK_EVENT_KEY,
      escaped,
      M.hook_timeout_sec()
    ),
  }
end

M._HOOK_EVENT_KEY = HOOK_EVENT_KEY

--- Exported for the one caller that has to take the flag back **out**: `app-server` accepts the
--- hook override but not exec's trust bypass, so the resident transport filters it from the argv
--- it was handed (`codex_command_builder.resident_hook_args`). A second spelling of the literal
--- there would go stale in silence -- the flag would simply stop being filtered, and a rename
--- here would leave app-server being passed a flag that makes it refuse to start.
M.TRUST_FLAG = TRUST_FLAG

return M
