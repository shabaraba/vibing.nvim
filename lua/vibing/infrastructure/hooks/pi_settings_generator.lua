--- How the PreToolUse gate reaches the Pi coding agent: the `extension_file` transport.
---
--- Pi has **no external-process hook**. Its only interception point is an in-process TypeScript
--- handler registered by an extension (`pi --extension <path>`), so there is nothing to generate
--- here in the sense the other four transports generate something. This module resolves the
--- extension that ships with the plugin and hands its path to the argv, and the extension spawns
--- the same `bin/hooks/pre-tool-use.sh` every other backend uses.
---
--- Two consequences follow, both of which the other transports do not have:
---
--- **Nothing is written per cwd or per instance.** The other generators key their output by
--- `rpc/instance_key.lua` because the file they write carries a timeout derived from
--- `permissions.approval_wait_sec`, and a second Neovim rewriting it could put the CLI's deadline
--- ahead of the script's. Here the deadline never lands in a file: it reaches the extension in the
--- child's environment (`pi.apply_env`), fixed at spawn, so the sharing hazard does not arise.
---
--- **A missing bundle raises, and the run degrades rather than continuing at full capability.**
--- `cli_adapter` warns and carries on when a transport raises, which is the right trade for a
--- backend whose CLI has its own gate underneath. Pi has none, so
--- `pi_command_builder.permission_args` reads the resulting nil `hook_arg` and restricts the run to
--- read-only tools. Raising here is what produces that nil, and the warning that explains it.
--- @module vibing.infrastructure.hooks.pi_settings_generator

local M = {}

--- The PreToolUse timeout this transport registers, in seconds.
---
--- Pi applies no timeout of its own to an extension handler, so unlike the other four this number
--- is not something a CLI was configured with — it is the deadline **the extension itself**
--- enforces, read from `VIBING_PI_HOOK_TIMEOUT_SEC` (`pi.apply_env`). Reporting it is not a
--- formality: `hook_timeout_ordering_spec` refuses a transport that answers nil, on the ground that
--- "no timeout" and "a schema this check cannot see into" are indistinguishable from the outside.
---
--- The ordering it takes part in is the usual one,
--- `approval_wait_sec < script wait < this`, but its justification is inverted. Elsewhere the last
--- inequality matters because a CLI past its own timeout **fails open** and runs the tool with no
--- verdict. The extension fails **closed**, so here the inequality only keeps a slow-but-answered
--- approval from being cut short. Both sides being derived from `wait_budget` is what keeps that
--- true when a user changes `approval_wait_sec`.
--- @return number seconds
function M.hook_timeout_sec()
  return require("vibing.infrastructure.hooks.wait_budget").cli_timeout_sec()
end

--- Where the built extension lives, relative to the plugin root.
local BUNDLE_RELATIVE_PATH = "/pi-extension/dist/index.js"

--- @return string absolute path to the plugin root
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h:h:h")
end

--- Absolute path of the built permission-bridge extension, whether or not it exists.
--- @return string
function M.bundle_path()
  return plugin_root() .. BUNDLE_RELATIVE_PATH
end

--- Resolve the extension for one run.
---
--- Takes `cwd` and `dialect` to match the transport signature; it uses neither. The dialect the
--- extension speaks is fixed at `claude`, because it reads the shared script's **exit code** rather
--- than its stdout, and that is the code path claude's branch describes. A Pi-specific dialect
--- would be a second spelling of a decision the script already phrases.
--- @param _cwd string? unused
--- @param _dialect string? unused
--- @return string path Absolute path to the extension, for `--extension`
function M.ensure(_cwd, _dialect)
  local path = M.bundle_path()
  if vim.fn.filereadable(path) == 0 then
    error(
      string.format(
        "the Pi permission bridge is not built (%s). Run ./build.sh in the vibing.nvim checkout; "
          .. "without it Pi would run its bash and write tools with no permission gate at all.",
        path
      ),
      0
    )
  end
  return path
end

return M
