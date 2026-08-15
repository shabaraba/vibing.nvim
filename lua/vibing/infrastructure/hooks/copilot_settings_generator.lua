--- Copilot CLI hook settings generator
--- Writes a throwaway Copilot *plugin* to <cwd>/.vibing/copilot-plugin/ whose manifest registers
--- vibing's pre-tool-use.sh as a `preToolUse` hook. `copilot --plugin-dir <dir>` loads it for that
--- run only, which is what gives the Copilot backend the Tool Approval UI (#512).
---
--- Why a plugin rather than the two hook locations Copilot documents: `~/.copilot/hooks/` is the
--- user's own config (vibing.nvim must not write there) and `.github/hooks/` is the user's
--- repository. `--plugin-dir` is per-run, needs no global state, and is the only one of the three
--- that leaves both alone.
--- @module vibing.infrastructure.hooks.copilot_settings_generator

local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local Fs = require("vibing.core.utils.fs")

local M = {}

--- Copilot requires a kebab-case plugin name (max 64 chars).
local PLUGIN_NAME = "vibing-nvim-permissions"

--- Copilot's own hook timeout **fails open** — a hook that runs longer than this is ignored and
--- the tool proceeds, where every non-zero exit fails closed. pre-tool-use.sh gives up and denies
--- after ~120s, so this has to stay comfortably above that number or a slow approval would turn
--- into a silent allow.
local HOOK_TIMEOUT_SEC = 300

--- Absolute path to the generated plugin directory for a given cwd
--- Resolved, so this reports the same path `ensure()` writes: that one resolves the cwd, and a
--- symlinked working directory would otherwise make the two disagree.
--- @param cwd string
--- @return string
function M.plugin_dir(cwd)
  return vim.fn.resolve(cwd) .. "/.vibing/copilot-plugin"
end

--- Build the plugin manifest
---
--- The hooks are inlined rather than pointed at a sibling `hooks.json`, which keeps the plugin to
--- a single file. Note the inline object is the bare event map: the `{"version": 1, "hooks": …}`
--- envelope that a standalone hooks file requires is silently ignored here (both forms were run
--- against copilot 1.0.78 — only this one reaches the hook registry).
---
--- The rest of the schema is Copilot's own, not Claude's: lowercase `preToolUse`, the command
--- under `bash`, and `timeoutSec` rather than `timeout`. The matcher is omitted on purpose — in
--- camelCase events it is compiled as a regex (`^(?:PATTERN)$`), so the `*` that means "all tools"
--- in Claude's PascalCase form is rejected with "Invalid matcher regex … hook will be skipped"
--- (observed in ~/.copilot/logs). No matcher means every tool.
--- @param hook_command string Shell command line to run for each tool call
--- @return table
local function build_manifest(hook_command)
  return {
    name = PLUGIN_NAME,
    description = "vibing.nvim tool approval bridge (generated; safe to delete)",
    version = "1.0.0",
    hooks = {
      preToolUse = {
        {
          type = "command",
          bash = hook_command,
          timeoutSec = HOOK_TIMEOUT_SEC,
        },
      },
    },
  }
end

--- Ensure the Copilot plugin directory exists for the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @return string path Absolute path to the plugin directory, for `--plugin-dir`
function M.ensure(cwd)
  local dir = M.plugin_dir(cwd or vim.fn.getcwd())
  Fs.ensure_dir(dir)

  -- The `copilot` argument switches the script to Copilot's decision format; see the script.
  -- Shell-escaped because Copilot runs this string through a shell, and a plugin path under a
  -- checkout with a space in it would otherwise split into two arguments.
  local script = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local hook_command = vim.fn.shellescape(script) .. " copilot"

  -- Always regenerated: the hook script path moves when the plugin is updated or reinstalled.
  --
  -- Written through a temp file and renamed, because this path is shared by every chat open on
  -- this cwd and each one rewrites it just before spawning its own copilot. Truncating in place
  -- would give a copilot that happens to be reading the manifest at that moment a partial file —
  -- and an unreadable manifest means no hook, which is the one failure mode that fails *open*.
  -- rename(2) is atomic within a directory, so a concurrent reader sees either version whole.
  --
  -- What makes one shared path safe at all is that the contents are the same for every chat: the
  -- per-request identity (`VIBING_HANDLE_ID`, the RPC port) travels in copilot's environment, not
  -- in this file. Anything that has to differ per chat therefore belongs in the environment too —
  -- putting it here would make concurrent chats overwrite each other's manifest, and this
  -- directory would have to become per-handle instead.
  local path = dir .. "/plugin.json"
  local tmp_path = string.format("%s.%d.tmp", path, vim.loop.getpid())
  local f, err = io.open(tmp_path, "w")
  if not f then
    error("Failed to create Copilot plugin manifest: " .. tmp_path .. " (" .. tostring(err) .. ")")
  end
  f:write(vim.json.encode(build_manifest(hook_command)))
  f:close()

  local ok, rename_err = os.rename(tmp_path, path)
  if not ok then
    os.remove(tmp_path)
    error("Failed to install Copilot plugin manifest: " .. path .. " (" .. tostring(rename_err) .. ")")
  end

  return dir
end

return M
