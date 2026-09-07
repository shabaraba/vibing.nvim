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
--- pre-tool-use.sh gives up and denies after ~120s, so this stays above that number for the same
--- reason copilot's does: whichever side gives up first decides, and the script's deny is the only
--- one that carries a reason.
local HOOK_TIMEOUT_SEC = 300

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
--- Copied rather than cached: the source path moves when the plugin is updated or reinstalled, and
--- a stale copy is a hook that silently answers with old logic. The write goes through a temp file
--- and a rename because every chat open on this cwd rewrites this path just before spawning its own
--- codex, and a reader catching a truncated script would get a hook that fails in a way none of the
--- three decisions covers. `rename(2)` is atomic within a directory. One shared path is safe only
--- because the contents are identical for every chat -- per-request identity (`VIBING_HANDLE_ID`,
--- the RPC port) travels in codex's environment, not in this file.
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
--- @return string[] argv fragment: {"--dangerously-bypass-hook-trust", "-c", "hooks.PreToolUse=[...]"}
function M.get_hook_args(cwd)
  local script = M.ensure(cwd)
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
      HOOK_TIMEOUT_SEC
    ),
  }
end

M._HOOK_EVENT_KEY = HOOK_EVENT_KEY
M._HOOK_TIMEOUT_SEC = HOOK_TIMEOUT_SEC

return M
