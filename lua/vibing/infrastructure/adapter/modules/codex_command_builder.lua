--- The parts of the `codex exec --json` argv a flag table cannot express (ADR 009 P2).
---
--- The request itself is `request` in `backends/codex.lua`; `request_builder.lua` resolves the
--- shared values. What stays here maps vibing.nvim's permission mode onto codex's sandbox and
--- project profile, applies the auto-compact threshold, and carries the plugins in as `-c`
--- overrides. `build()` remains as the historical entry point over that spec.
--- @module vibing.infrastructure.adapter.modules.codex_command_builder

local CodexTurnSettings = require("vibing.infrastructure.adapter.modules.codex_turn_settings")
local CodexPluginConfig = require("vibing.infrastructure.adapter.modules.codex_plugin_config")
local CodexPermissionProfile = require("vibing.infrastructure.adapter.modules.codex_permission_profile")
local TokenUsage = require("vibing.core.utils.token_usage")

local M = {}

local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")

M.BINARY = { name = "codex", missing = "Codex CLI not found in PATH. Please install codex-cli." }

--- Apply vibing.nvim's shared auto_compact threshold through Codex's native compaction setting.
---
--- Claude needs a separate `/compact` turn because that is the seam its headless CLI exposes.
--- Codex already owns compaction inside the running turn, including the context accounting that
--- its JSONL stream does not report to vibing.nvim, so inserting prompt text here would be both
--- too late and the wrong protocol. A per-process `-c` override reaches new and resumed threads
--- alike without writing to the user's config.toml.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.auto_compact_args(ctx)
  local config = ctx.config
  local agent = type(config) == "table" and config.agent or nil
  local token_usage = type(agent) == "table" and agent.token_usage or nil
  local auto_compact = type(token_usage) == "table" and token_usage.auto_compact or nil
  if type(auto_compact) ~= "table" or not auto_compact.enabled then
    return {}
  end

  local at = tonumber(auto_compact.at) or TokenUsage.DEFAULT_AUTO_COMPACT_AT
  if at <= 0 or at ~= at or at == math.huge then
    return {}
  end

  -- Codex expects an integer token count. config.lua documents a number rather than an integer,
  -- so make a fractional value deterministic instead of handing the CLI invalid TOML.
  at = math.max(1, math.floor(at))

  return { "-c", string.format("model_auto_compact_token_limit=%d", at) }
end

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec
--- exercising the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  RequestBuilder.reset_binary(require("vibing.infrastructure.adapter.backends.codex").request)
end

--- What a lightweight utility call runs under, in place of the permission flags.
--- Lightweight calls need no tools, but codex has no way to remove them. Probing the config
--- schema with `--strict-config` (which rejects unknown fields) against codex 0.147:
--- tools.shell, tools.apply_patch, tools.view_image, tools.plan_tool and tools.mcp are all
--- "unknown configuration field", and tools.web_search is the only tool toggle that exists.
--- There is no `--tools ""` equivalent, so the tools cannot be taken away -- only fenced in.
---
--- These are `-c` overrides rather than the `-s`/`--sandbox` flag because /summarize passes a
--- session id, and `codex exec resume` does not accept `-s`. sandbox_mode is what `-s` sets.
---
--- This deliberately ignores permission_mode, including bypassPermissions: the user put the
--- *chat* in that mode, and a title generated behind their back is not the call they made.
--- read-only blocks writes *and* network, verified by running commands under `codex sandbox`
--- rather than read off the docs: a write reports "Operation not permitted" and curl returns
--- 000 where the same request outside the sandbox returns 200. That closes the exfiltration
--- path a prompt injection in the summarized transcript would otherwise have, which matters
--- because the shell tool itself cannot be taken away.
---
--- `--ignore-user-config` is what actually keeps the user's MCP servers out. It replaced
--- `-c mcp_servers={}`, which looked equivalent and did nothing: `-c` *deep-merges* into
--- config.toml, so an empty table adds no keys and removes none. Measured against codex
--- 0.147, not inferred -- `codex mcp list -c 'mcp_servers={}'` still lists every configured
--- server, and under `codex exec` a server whose command touches a file still got launched and
--- still wrote it. That last part is why this is a boundary and not a preference: codex spawns
--- MCP servers itself, so the process runs *outside* the read-only sandbox above. There is no
--- narrower switch -- mcp.enabled, tools.mcp, features.mcp, mcp_enabled and disable_mcp are all
--- unknown fields, `mcp_servers=false` is a type error, and per-server
--- `mcp_servers.<name>.enabled=false` works but needs a name list that would go stale silently
--- the moment the user added a server.
---
--- The cost is the one #571 named: this also drops model_provider, so a user on a custom
--- provider gets utility calls against the default OpenAI endpoint. Accepted now that the
--- alternative is known to be a hole rather than an equivalent. Auth is unaffected -- codex
--- reads it from CODEX_HOME either way.
--- `--strict-config` makes codex reject unknown config keys, so the day it renames or drops one
--- of the overrides below, the utility call fails loudly instead of quietly running unfenced.
--- Every restriction here is a safety boundary whose absence is otherwise unobservable, so this
--- fails closed on purpose (#574).
---
--- This is only safe in company with --ignore-user-config: on its own, --strict-config also
--- strictifies the user's config.toml, and one unrecognised field of their own would break
--- every title generation. With the user config unread, it validates our overrides and nothing
---
--- @type string[]
M.LIGHTWEIGHT_ARGS = {
  "--ignore-user-config",
  "--strict-config",
  "-c",
  'sandbox_mode="read-only"',
  "-c",
  "tools.web_search=false",
  "-c",
  'approval_policy="never"',
  "-c",
  "project_doc_max_bytes=0",
}

--- The user's `backends.codex.approval_policy`, as the `-c` pair it becomes, or nothing.
---
--- Applied only on the branches that make no statement of their own: `bypassPermissions` already
--- means "ask nothing" and `plan` already means "write nothing", and a configured policy must not
--- quietly undo either. On every other branch this is what turns codex's own approval requests on
--- (#861) — the argv is the duplex reuse key, so changing it starts a fresh process and therefore
--- reaches resumed threads as well as new ones.
---
--- Returning nothing means "say nothing", which is the right answer on the exec path and the wrong
--- one on the resident path; `resident_permission_args` is where that difference is decided.
--- @param ctx Vibing.RequestContext
--- @return string[]
local function approval_policy_args(ctx)
  local policy = vim.tbl_get(ctx.config or {}, "backends", "codex", "approval_policy")
  if type(policy) ~= "string" or policy == "" then
    return {}
  end
  return { "-c", string.format('approval_policy="%s"', policy) }
end

--- The permission mapping for an ordinary call. A project-local permission profile is a config
--- layer, so unlike `-s` it is valid on `codex exec resume` and must be supplied on every process
--- invocation. Keeping the rendered overrides byte-stable also keeps the model-visible permission
--- prefix stable for prompt caching; the file path and its source location are never added to
--- the prompt.
--- @param ctx Vibing.RequestContext
--- @return string[]
--- The permission mapping for a resident app-server.
---
--- Its own builder rather than a branch inside `permission_args`, because "is this call duplex"
--- is already a first-class condition on the parts list (`when = "duplex"`), which is how every
--- other argv difference in this descriptor is stated. A second spelling of the same condition
--- inside a builder is one the parts list cannot see.
---
--- Two things differ from the exec mapping, and only two. `-s` does not exist here, so every mode
--- travels as a `-c` override -- the shape exec already uses when resuming. And the approval
--- policy is **always stated**, never left at codex's own default: a request this transport
--- cannot put in front of a human is declined (#861 routes the ones it can, and refuses the rest
--- when there is no chat to ask or the configured wait is longer than the backend was measured to
--- tolerate), so an unstated policy turns a sandboxed action into a silent denial instead of
--- something vibing's own PreToolUse hook and permission rules get to decide. `never` unless the
--- user asked for something else; the exec path below has no such channel to fail on and keeps
--- passing nothing.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.resident_permission_args(ctx)
  -- `bypassPermissions` already means "ask nothing" and `plan` already means "write nothing", so
  -- neither consults the configured policy -- it must not quietly undo either.
  if ctx.opts.permission_mode == "bypassPermissions" then
    return { "-c", 'sandbox_mode="danger-full-access"', "-c", 'approval_policy="never"' }
  elseif ctx.opts.permission_mode == "plan" then
    return { "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"' }
  end

  local profile_args = CodexPermissionProfile.args(ctx.opts.cwd, ctx.config)
  -- A fresh table, never the profile's own: `CodexPermissionProfile.args` is memoised per cwd,
  -- so appending below would grow the cached argv on every turn.
  local args = #profile_args > 0 and vim.list_extend({}, profile_args) or { "-c", 'sandbox_mode="workspace-write"' }

  local policy = approval_policy_args(ctx)
  if #policy == 0 then
    policy = { "-c", 'approval_policy="never"' }
  end
  return vim.list_extend(args, policy)
end

function M.permission_args(ctx)
  local opts, session_id, config = ctx.opts, ctx.session_id, ctx.config
  local cmd = {}
  local permission_mode = opts.permission_mode
  if permission_mode == "bypassPermissions" then
    table.insert(cmd, "--dangerously-bypass-approvals-and-sandbox")
  elseif permission_mode == "plan" then
    if session_id then
      -- `resume` does not accept `-s`; the equivalent config override does. It intentionally
      -- wins over a project profile because plan mode is an explicit read-only request.
      table.insert(cmd, "-c")
      table.insert(cmd, 'sandbox_mode="read-only"')
    else
      table.insert(cmd, "-s")
      table.insert(cmd, "read-only")
    end
  else
    local profile_args = CodexPermissionProfile.args(opts.cwd, config)
    if #profile_args > 0 then
      vim.list_extend(cmd, profile_args)
    elseif not session_id then
      -- Only "default"/"acceptEdits"/"auto"/"dontAsk"/nil reach here -- "plan" and
      -- "bypassPermissions" are both handled above -- so the sandbox is always workspace-write.
      table.insert(cmd, "-s")
      table.insert(cmd, "workspace-write")
    end
    -- Same branch condition as the duplex path above, for the same reason: the two explicit modes
    -- already say what they want about asking, and this one must not undo them.
    vim.list_extend(cmd, approval_policy_args(ctx))
  end
  return cmd
end

--- The plugins `--plugin-dir` would carry on the claude path: vibing.nvim's own MCP server and
--- skills, plus `.vibing/plugins/*/`, as `-c mcp_servers.*` and `-c developer_instructions`
--- overrides (see codex_plugin_config). Applied on resume too -- config is per process, and a
--- resumed thread that lost its tools would be a different chat.
---
--- Not on the lightweight path, for the same reason claude passes no `--plugin-dir` there: a
--- utility call owes "no tools, no user MCP servers" (`core/types.lua`), and these would be both.
--- `--ignore-user-config --strict-config` would also reject nothing here, since every key is one
--- codex knows -- the fence is the condition on this part, not the flags.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.plugin_args(ctx)
  return CodexPluginConfig.args(ctx.opts.cwd, ctx.config, ctx.opts.chat_bufnr)
end

--- app-server accepts the hook override but not exec's trust-bypass flag.
--- The protocol checks hooks/list before starting a thread, rather than silently losing the gate.
function M.resident_hook_args(ctx)
  local trust_flag = require("vibing.infrastructure.hooks.codex_settings_generator").TRUST_FLAG
  local args = {}
  for _, arg in ipairs(ctx.hook_arg or {}) do
    if arg ~= trust_flag then
      table.insert(args, arg)
    end
  end
  return args
end

--- One shared selection for the one-shot argv; app-server sends the same selection per turn.
function M.oneshot_selection_args(ctx)
  local selection = CodexTurnSettings.resolve(ctx.opts, ctx.config)
  local args = {}
  if selection.model then
    vim.list_extend(args, { "-m", selection.model })
  end
  if selection.effort then
    vim.list_extend(args, { "-c", string.format('model_reasoning_effort="%s"', selection.effort) })
  end
  return args
end

--- Build the `codex exec --json` command array from the request spec in `backends/codex.lua`.
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Thread ID for session resumption
--- @param config Vibing.Config Plugin config
--- @param hook_args string[]|nil Optional argv fragment for PreToolUse hook injection. Opaque
---   here on purpose: `codex_settings_generator` decides what a registered hook needs, and it
---   needs more than the `-c` pair (see its TRUST_FLAG comment). Appended verbatim.
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, hook_args)
  return RequestBuilder.build(
    require("vibing.infrastructure.adapter.backends.codex").request,
    prompt,
    opts,
    session_id,
    config,
    hook_args
  )
end

return M
