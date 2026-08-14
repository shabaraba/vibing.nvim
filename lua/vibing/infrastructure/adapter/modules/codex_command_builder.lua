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
    table.insert(cmd, "-c")
    table.insert(cmd, 'sandbox_mode="read-only"')
    table.insert(cmd, "-c")
    table.insert(cmd, "tools.web_search=false")
    -- With the approval prompt unreachable in headless exec, anything that did ask would stall
    -- until the timeout. Verified value: one of untrusted/on-failure/on-request/granular/never.
    table.insert(cmd, "-c")
    table.insert(cmd, 'approval_policy="never"')
    -- The other two halves of what `lightweight` promises (core/types.lua): no MCP tools and no
    -- project instructions. These are codex's answers to claude's --strict-mcp-config/--mcp-config
    -- and --setting-sources "". `--ignore-user-config` would cover both and is deliberately not
    -- used: unlike claude's flag it also drops model_provider and base URL, so a user on a custom
    -- provider would lose utility calls entirely.
    table.insert(cmd, "-c")
    table.insert(cmd, "mcp_servers={}")
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
