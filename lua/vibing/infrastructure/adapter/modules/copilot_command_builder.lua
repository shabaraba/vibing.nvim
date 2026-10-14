--- The parts of the `copilot -p --output-format json` argv a flag table cannot express
--- (ADR 009 P2).
---
--- The request itself is `request` in `backends/copilot.lua`; `request_builder.lua` resolves the
--- shared values. What stays here is the permission mapping, which is mostly the generated hook
--- plugin plus a static deny backstop. `build()` remains as the historical entry point.
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")

local M = {}

M.BINARY = { name = "copilot", missing = "Copilot CLI not found in PATH. Please install GitHub Copilot CLI." }

local ToolVocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")

--- A tool name copilot does not have, handed to `--available-tools` to leave the model with an
--- empty toolset.
---
--- `--available-tools` is documented as the filter that "disables all other tools" and decides
--- "which tools the model can see" (`copilot help permissions`), so a list matching nothing
--- resolves to nothing. Verified against copilot 1.0.78 by counting the tool schemas in
--- `--log-level debug` output: an ordinary run offers 62 tools, `--available-tools=view` offers
--- exactly 1, and this sentinel offers 0 — and the turn still completes normally
--- (`toolRequests: []`, exit 0), so an empty toolset is not an error to copilot.
---
--- The value has to be a name rather than an empty string. `--available-tools=` parses as an
--- empty list, which copilot ignores outright: it left all 62 tools in place, the same silent
--- no-op grok has for `--tools ""`.
local NO_TOOLS_SENTINEL = "__vibing_no_tools__"

--- The permission flags. copilot's non-interactive mode requires --allow-all-tools, so the real
--- gate is the generated `preToolUse` hook (`--plugin-dir`, see copilot_settings_generator): it is
--- what carries `permission_mode`, the `ask` list and the Tool Approval UI. The static
--- `--deny-tool` patterns stay as a backstop that still applies if the plugin fails to load.
---
--- A lightweight call never reaches here -- the request spec conditions this part out and uses
--- `LIGHTWEIGHT_ARGS` instead, which is what keeps "registers no hooks" true for copilot no matter
--- what the adapter passes.
--- @param ctx Vibing.RequestContext `hook_arg` is the generated plugin directory, nil when no
---   hook was installed
--- @return string[]
function M.permission_args(ctx)
  local opts, plugin_dir = ctx.opts, ctx.hook_arg
  local cmd = {}
  local permission_mode = opts.permission_mode or "default"

  if permission_mode == "bypassPermissions" then
    table.insert(cmd, "--allow-all")
    return cmd
  end

  if permission_mode == "plan" then
    table.insert(cmd, "--plan")
  end
  table.insert(cmd, "--allow-all-tools")

  if plugin_dir then
    table.insert(cmd, "--plugin-dir")
    table.insert(cmd, plugin_dir)
  end

  for _, pattern in ipairs(ToolVocabulary.build_deny_patterns(opts.permissions_deny)) do
    table.insert(cmd, "--deny-tool")
    table.insert(cmd, pattern)
  end
  return cmd
end

--- The flags a lightweight utility call (title generation, /summarize, daily summary) runs
--- under, in place of the permission flags.
---
--- This is copilot's half of what `lightweight` promises in `core/types.lua`. Unlike codex,
--- copilot can genuinely take the tools away, so there is no sandbox to fence anything into:
--- `--available-tools` filters the user's MCP tools too (the 62-tool baseline above includes
--- them, and the sentinel leaves 0), which covers claude's `--strict-mcp-config` in one flag.
--- The MCP servers themselves are still spawned, but expose nothing to the model.
---
--- `--allow-all-tools` stays because copilot requires it in non-interactive mode at all, not
--- because anything is left to allow. `permission_mode` is deliberately ignored,
--- `bypassPermissions` included: the user put the *chat* in that mode, and a title generated
--- behind their back is not the call they made.
---
--- `--no-custom-instructions` is claude's `--setting-sources ""` and codex's
--- `project_doc_max_bytes=0`. Verified on 1.0.78: an AGENTS.md sentinel string reaches the
--- prompt twice without this flag and not at all with it.
--- @type string[]
M.LIGHTWEIGHT_ARGS = { "--allow-all-tools", "--available-tools=" .. NO_TOOLS_SENTINEL, "--no-custom-instructions" }

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec
--- exercising the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  RequestBuilder.reset_binary(require("vibing.infrastructure.adapter.backends.copilot").request)
end

--- Build the `copilot -p --output-format json` command array from the request spec in
--- `backends/copilot.lua`.
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @param plugin_dir? string Generated hook plugin directory to load with --plugin-dir
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, plugin_dir)
  return RequestBuilder.build(
    require("vibing.infrastructure.adapter.backends.copilot").request,
    prompt,
    opts,
    session_id,
    config,
    plugin_dir
  )
end

return M
