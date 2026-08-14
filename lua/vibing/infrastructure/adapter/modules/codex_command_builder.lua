--- Codex CLI command builder for `codex exec --json` execution
--- Builds the command array for the Codex CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.codex_command_builder

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")

local M = {}

local binary_path = CommonBuilder.binary_resolver(
  "codex",
  "Codex CLI not found in PATH. Please install codex-cli."
)

--- Map vibing permission mode to codex sandbox flag
--- @param permission_mode string|nil
--- @return string|nil sandbox flag value, or nil for default
local function resolve_sandbox(permission_mode)
  if permission_mode == "plan" then
    return "read-only"
  end
  if permission_mode == "bypassPermissions" then
    return nil -- use --dangerously-bypass flag instead
  end
  return "workspace-write"
end

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec
--- exercising the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  binary_path.reset()
end

--- Build the `codex exec --json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Thread ID for session resumption
--- @param config Vibing.Config Plugin config
--- @param hook_args string[]|nil Optional -c flag pair for PreToolUse hook injection
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, hook_args)
  local cmd = { binary_path.resolve(), "exec" }

  if session_id then
    table.insert(cmd, "resume")
    table.insert(cmd, session_id)
  end

  table.insert(cmd, "--json")

  -- Hook injection for permission control
  if hook_args then
    for _, arg in ipairs(hook_args) do
      table.insert(cmd, arg)
    end
  end

  -- Model selection
  local model = NonClaudeModel.resolve(opts, config)
  if model then
    table.insert(cmd, "-m")
    table.insert(cmd, model)
  end

  if opts.lightweight then
    -- Lightweight calls need no tools, but codex has no way to remove them. Probing the config
    -- schema with `--strict-config` (which rejects unknown fields) against codex 0.147:
    -- tools.shell, tools.apply_patch, tools.view_image, tools.plan_tool and tools.mcp are all
    -- "unknown configuration field", and tools.web_search is the only tool toggle that exists.
    -- There is no `--tools ""` equivalent, so the tools cannot be taken away -- only fenced in.
    --
    -- These are `-c` overrides rather than the `-s`/`--sandbox` flag because /summarize passes a
    -- session id, and `codex exec resume` does not accept `-s`. sandbox_mode is what `-s` sets.
    --
    -- This deliberately ignores permission_mode, including bypassPermissions: the user put the
    -- *chat* in that mode, and a title generated behind their back is not the call they made.
    -- read-only blocks writes *and* network, verified by running commands under `codex sandbox`
    -- rather than read off the docs: a write reports "Operation not permitted" and curl returns
    -- 000 where the same request outside the sandbox returns 200. That closes the exfiltration
    -- path a prompt injection in the summarized transcript would otherwise have, which matters
    -- because the shell tool itself cannot be taken away.
    --
    -- `--ignore-user-config` is what actually keeps the user's MCP servers out. It replaced
    -- `-c mcp_servers={}`, which looked equivalent and did nothing: `-c` *deep-merges* into
    -- config.toml, so an empty table adds no keys and removes none. Measured against codex
    -- 0.147, not inferred -- `codex mcp list -c 'mcp_servers={}'` still lists every configured
    -- server, and under `codex exec` a server whose command touches a file still got launched and
    -- still wrote it. That last part is why this is a boundary and not a preference: codex spawns
    -- MCP servers itself, so the process runs *outside* the read-only sandbox above. There is no
    -- narrower switch -- mcp.enabled, tools.mcp, features.mcp, mcp_enabled and disable_mcp are all
    -- unknown fields, `mcp_servers=false` is a type error, and per-server
    -- `mcp_servers.<name>.enabled=false` works but needs a name list that would go stale silently
    -- the moment the user added a server.
    --
    -- The cost is the one #571 named: this also drops model_provider, so a user on a custom
    -- provider gets utility calls against the default OpenAI endpoint. Accepted now that the
    -- alternative is known to be a hole rather than an equivalent. Auth is unaffected -- codex
    -- reads it from CODEX_HOME either way.
    table.insert(cmd, "--ignore-user-config")
    -- `--strict-config` makes codex reject unknown config keys, so the day it renames or drops one
    -- of the overrides below, the utility call fails loudly instead of quietly running unfenced.
    -- Every restriction here is a safety boundary whose absence is otherwise unobservable, so this
    -- fails closed on purpose (#574).
    --
    -- This is only safe in company with --ignore-user-config: on its own, --strict-config also
    -- strictifies the user's config.toml, and one unrecognised field of their own would break
    -- every title generation. With the user config unread, it validates our overrides and nothing
    -- else. Both flags have existed since at least codex 0.140 and are accepted on
    -- `codex exec resume` too, so unlike `-s` neither is lost on the /summarize path.
    table.insert(cmd, "--strict-config")
    table.insert(cmd, "-c")
    table.insert(cmd, 'sandbox_mode="read-only"')
    table.insert(cmd, "-c")
    table.insert(cmd, "tools.web_search=false")
    -- With the approval prompt unreachable in headless exec, anything that did ask would stall
    -- until the timeout. Verified value: one of untrusted/on-failure/on-request/granular/never.
    table.insert(cmd, "-c")
    table.insert(cmd, 'approval_policy="never"')
    -- The last piece of what `lightweight` promises (core/types.lua): no project instructions.
    -- codex's answer to claude's --setting-sources "". `--ignore-user-config` does *not* cover
    -- this: AGENTS.md is discovered from the cwd, not from config.toml, so ignoring the user
    -- config only restores this key's 32768-byte default. Verified with `codex debug prompt-input`
    -- (which renders the model-visible prompt without calling the model): a marker line in
    -- AGENTS.md is present without this override and absent with it.
    table.insert(cmd, "-c")
    table.insert(cmd, "project_doc_max_bytes=0")

  -- Permission mapping (only for new sessions; resume does not accept -s)
  elseif not session_id then
    local permission_mode = opts.permission_mode
    if permission_mode == "bypassPermissions" then
      table.insert(cmd, "--dangerously-bypass-approvals-and-sandbox")
    else
      local sandbox = resolve_sandbox(permission_mode)
      if sandbox then
        table.insert(cmd, "-s")
        table.insert(cmd, sandbox)
      end
    end
  end

  -- Build prompt with context prefix and language instruction
  local full_prompt = prompt
  if not session_id then
    local context_prefix = CommonBuilder.context_prefix(opts)
    full_prompt = context_prefix .. prompt
  end

  local language_instruction = CommonBuilder.language_instruction(opts, config)
  if language_instruction then
    full_prompt = language_instruction .. "\n\n" .. full_prompt
  end

  table.insert(cmd, full_prompt)

  return cmd
end

return M
