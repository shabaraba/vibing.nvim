--- Copilot CLI hook settings generator
--- Writes a throwaway Copilot *plugin* to <cwd>/.vibing/copilot-plugin-<instance>/ whose manifest registers
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
--- the tool proceeds, where every non-zero exit fails closed. So this has to stay above the
--- deadline pre-tool-use.sh gives itself, or a slow approval turns into a silent allow. Both come
--- from `permissions.approval_wait_sec` through `wait_budget.lua`, which is what keeps them in
--- order; this was the one generator that said so, and the only one whose spec checked it.
---
--- What this transport registers as its PreToolUse timeout. See
--- `settings_generator.hook_timeout_sec` for why every transport answers this.
--- @return number|nil seconds
function M.hook_timeout_sec()
  return require("vibing.infrastructure.hooks.wait_budget").cli_timeout_sec()
end

--- Absolute path to the generated plugin directory for a given cwd
---
--- Resolved, so this reports the same path `ensure()` writes: that one resolves the cwd, and a
--- symlinked working directory would otherwise make the two disagree.
---
--- **Keyed by instance**, for the reason spelled out on `settings_generator.settings_path`: the
--- manifest carries a `timeoutSec` derived from this Neovim's `permissions.approval_wait_sec`,
--- and a second Neovim with a lower one must not be able to rewrite it under a copilot of ours
--- that is already running. The comment below about one shared path being safe "because the
--- contents are the same for every chat" held only while nothing in here depended on
--- configuration; the timeout does.
--- @param cwd string
--- @return string
function M.plugin_dir(cwd)
  return string.format(
    "%s/.vibing/copilot-plugin-%s",
    vim.fn.resolve(cwd),
    require("vibing.infrastructure.rpc.instance_key").get()
  )
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
          timeoutSec = M.hook_timeout_sec(),
        },
      },
    },
  }
end

--- Delete plugin directories left behind by Neovims that are no longer running.
--- @param vibing_dir string
local function sweep_dead_instances(vibing_dir)
  local InstanceKey = require("vibing.infrastructure.rpc.instance_key")
  InstanceKey.sweep(vibing_dir, "^copilot%-plugin%-(" .. InstanceKey.PATTERN .. ")$", function(path)
    vim.fn.delete(path, "rf")
  end)
end

--- Ensure the Copilot plugin directory exists for the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @param dialect? string how the script should phrase its decision (`hooks/transports.lua`).
---   Defaults to `copilot`, the only dialect copilot itself reads.
--- @return string path Absolute path to the plugin directory, for `--plugin-dir`
function M.ensure(cwd, dialect)
  local resolved = vim.fn.resolve(cwd or vim.fn.getcwd())
  local dir = M.plugin_dir(resolved)
  Fs.ensure_dir(dir)
  sweep_dead_instances(resolved .. "/.vibing")

  -- The `copilot` argument switches the script to Copilot's decision format; see the script.
  -- Shell-escaped because Copilot runs this string through a shell, and a plugin path under a
  -- checkout with a space in it would otherwise split into two arguments.
  local script = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local hook_command = vim.fn.shellescape(script) .. " " .. (dialect or "copilot")

  -- Always regenerated: the hook script path moves when the plugin is updated or reinstalled.
  --
  -- Written through a temp file and renamed, because this path is shared by every chat open on
  -- this cwd and each one rewrites it just before spawning its own copilot. Truncating in place
  -- would give a copilot that happens to be reading the manifest at that moment a partial file —
  -- and an unreadable manifest means no hook, which is the one failure mode that fails *open*.
  -- rename(2) is atomic within a directory, so a concurrent reader sees either version whole.
  --
  -- What makes one path safe to share between *chats* is that the contents are the same for every
  -- chat in this Neovim: the per-process identity (`VIBING_PROCESS_ID`, the RPC port) travels in
  -- copilot's environment, not in this file. Anything that has to differ per chat therefore belongs
  -- in the environment too.
  --
  -- It is not shared between *Neovims* any more, because `timeoutSec` does depend on configuration
  -- — see `plugin_dir`.
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
