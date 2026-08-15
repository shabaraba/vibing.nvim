--- Grok CLI command builder for `grok -p` / `--single` execution
--- Builds the command array for the Grok Build CLI with streaming JSON output
--- @module vibing.infrastructure.adapter.modules.grok_command_builder

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")
local worktree_constants = require("vibing.core.constants.worktree")

local M = {}

-- Grok's --permission-mode only accepts default/dontAsk/acceptEdits/bypassPermissions/plan.
-- vibing's "auto" mode (Claude's background safety classifier) has no Grok equivalent, so it
-- falls back to asking for confirmation instead of forwarding an unsupported value.
local GROK_PERMISSION_MODE_FALLBACK = {
  auto = "default",
}

--- The tool allowlist a lightweight utility call runs under.
---
--- Grok's `--tools` is an allowlist ("only the listed tools will be available; all others are
--- removed"), but it **fails open** on anything it cannot map to a real tool id. Verified against
--- grok 0.2.101 via `--debug-file`: `--tools "none"` logs
--- `tools allowlist had unmappable entries; keeping full grok toolset` and leaves every tool in
--- place, and `--tools ""` is ignored outright — the advertised tool count is unchanged from a
--- plain run either way. So the copilot trick of naming nothing is exactly wrong here; the list
--- has to name a tool grok actually has.
---
--- `todo_write` is that tool. Of grok's built-ins (`run_terminal_cmd`, `grep`, `read_file`,
--- `search_replace`, `list_dir`, `web_search`, `web_fetch`, `todo_write`, `task`) it is the only
--- one that touches no file, no shell and no network — it writes an in-session todo list and
--- nothing else. With it the run logs `tools allowlist applied allowed=["todo_write"]` and the
--- toolset drops from 26 to 3 (the tool plus grok's two always-on MCP meta-tools).
local LIGHTWEIGHT_TOOLS = "todo_write"

--- Deny rule covering every MCP tool, in the `MCPTool(server__tool)` form grok's permission
--- rules require -- an `mcp__server__tool` pattern never matches.
---
--- Needed because `--tools` filters grok's *built-in* tools only; the tools its MCP servers
--- expose are added on top regardless, and grok offers no per-run way to turn those servers off.
--- The allowlist cannot reach them, so execution is denied instead. This is weaker than claude's
--- empty `--mcp-config`, which stops them being offered at all.
---
--- Not redundant with the `dontAsk` mode below, which is the tempting reading. grok's own docs
--- say `dontAsk` stops short of auto-denying while always-approve is on, and grok imports the
--- user's `settings.json` permission rules -- so an allow rule there could pre-approve an MCP
--- tool. An explicit deny is what survives both: grok evaluates `deny` > `ask` > `allow`,
--- "regardless of order or source".
---
--- Both halves of that were measured against grok 0.2.101 rather than trusted to the docs:
---
--- 1. The rule *form* is recognised. Loading it from a `.grok/config.toml` moves
---    `grok inspect`'s permission count from 1 to 2, while an invented kind
---    (`TotallyBogusKind(*)`) leaves it at 1 -- and is reported as "0 skipped", so an
---    unrecognised rule vanishes without a word. A wildcard that silently did nothing would look
---    exactly like one that worked.
--- 2. The rule is *enforced*, through this flag, against a real MCP call. Same prompt and flags
---    twice, `--deny` the only difference: without it the model reports the tool called
---    successfully; with it, "denied by a permission policy", and the debug log records
---    `deny rule matched (enforced before YOLO) tool="mcp:vibing-nvim__nvim_list_instances"`.
---    Both runs passed `--always-approve`, so "enforced before YOLO" is also the precedence
---    claim above, confirmed rather than assumed.
local LIGHTWEIGHT_MCP_DENY = "MCPTool(*)"

local cached_grok_path = nil
local cached_configured_executable = nil
local verified_official = false

--- Detect the official xAI Grok Build CLI (not community grok-dev)
--- @param path string
local function ensure_official_grok(path)
  if verified_official then
    return
  end
  -- Unit tests mock exepath to a non-executable path; skip sniff in that case
  if vim.fn.executable(path) == 0 then
    return
  end

  local version = vim.fn.system({ path, "--version" })
  -- Official: "grok 0.2.101 (5bc4b5dfadcf) [stable]"
  if type(version) == "string" and version:match("^grok%s+%d+%.%d+") then
    verified_official = true
    return
  end

  local help = vim.fn.system({ path, "--help" })
  if type(help) == "string" and help:find("streaming%-json") then
    verified_official = true
    return
  end

  error(
    "Found a 'grok' binary that does not appear to be the official xAI Grok Build CLI. "
      .. "Install from https://x.ai/cli or set config.grok.executable to the official binary path."
  )
end

--- Resolve path to the grok binary
--- @param config Vibing.Config
--- @return string
local function resolve_grok_path(config)
  local configured = config and config.grok and config.grok.executable

  if cached_grok_path and cached_configured_executable == configured then
    return cached_grok_path
  end

  local resolved
  if configured and configured ~= "auto" and configured ~= "" then
    if vim.fn.executable(configured) == 0 then
      error(
        string.format(
          "Grok CLI not found at configured path '%s'. Install the official xAI Grok Build CLI.",
          configured
        )
      )
    end
    resolved = configured
  else
    local found = vim.fn.exepath("grok")
    if found == "" then
      error(
        "Grok CLI not found in PATH. Install the official xAI Grok Build CLI "
          .. "(curl -fsSL https://x.ai/cli/install.sh | bash) or set config.grok.executable."
      )
    end
    resolved = found
  end

  -- Verify before caching. The other order makes the "not the official CLI" error fire exactly
  -- once: the second call hits the cache above, skips ensure_official_grok, and hands back the
  -- unofficial binary silently.
  verified_official = false
  ensure_official_grok(resolved)

  cached_grok_path = resolved
  cached_configured_executable = configured
  return cached_grok_path
end

--- Build the `grok -p` (headless single-turn) CLI command array
--- Uses `--single=<value>` (one argv token) rather than `-p <value>` so hyphen-leading
--- prompts are not misparsed as flags by clap.
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption

--- What goes into `--rules`, Grok's equivalent of a system prompt.
---
--- Deliberately much smaller than the Claude adapter's block: Grok reaches no vibing-nvim MCP
--- server, so instructing it to call `nvim_ask_user_question` or `nvim_highlight_range` would
--- name tools it cannot invoke. Only the backend-agnostic conventions go here.
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil rules `nil` when there is nothing to say, so the caller omits the flag —
---   grok reads an empty `--rules` as a rule rather than as silence. `nil` rather than `""`
---   matches `CommonBuilder.language_instruction` and makes the omission impossible to drop:
---   `table.insert(cmd, nil)` raises where an empty string would sail through.
local function build_rules(opts, config)
  local lines = {}

  local language_instruction = CommonBuilder.language_instruction(opts, config)
  if language_instruction then
    table.insert(lines, language_instruction)
  end

  -- A lightweight call has no tools to create a worktree with, so the convention would just be
  -- wasted prompt tokens describing a capability that isn't there. Matches the claude builder,
  -- which drops the same line from `--append-system-prompt`.
  if not opts.lightweight then
    table.insert(
      lines,
      "When creating a git worktree for isolated work, place it under "
        .. worktree_constants.DIR
        .. "<branch-name>/ at the repository root."
    )
  end

  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

--- Append the flags a lightweight utility call (title generation, /summarize, daily summary) runs
--- under, in place of the chat's permission mode.
---
--- Takes no `opts` on purpose: "the utility call does not inherit the chat's permission mode,
--- `bypassPermissions` included" is then enforced by the signature rather than by a comment. The
--- user put the *chat* in that mode, and a title generated behind their back is not the call they
--- made.
--- @param cmd string[]
local function append_lightweight_flags(cmd)
  table.insert(cmd, "--tools")
  table.insert(cmd, LIGHTWEIGHT_TOOLS)
  table.insert(cmd, "--deny")
  table.insert(cmd, LIGHTWEIGHT_MCP_DENY)
  -- codex's `approval_policy="never"`, in grok's vocabulary. grok_cli registers no hook for a
  -- lightweight call, so a mode that prompts would stall on an approval nothing can answer.
  table.insert(cmd, "--permission-mode")
  table.insert(cmd, "dontAsk")
end

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec that
--- wants to exercise the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  cached_grok_path = nil
  cached_configured_executable = nil
end

--- @param config Vibing.Config Plugin config
--- @param handle_id string|nil Unused. Kept so every backend's builder takes the same arguments;
---   grok reaches no vibing-nvim MCP server, so nothing here needs the handle. The value still
---   travels to the hook, via `VIBING_HANDLE_ID` in the environment `grok_cli` spawns with.
--- @param rpc_port number|nil Unused, for the same reason: passed through the environment, not argv.
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, handle_id, rpc_port)
  opts = opts or {}
  config = config or {}

  local grok_path = resolve_grok_path(config)

  local full_prompt = prompt
  if not session_id then
    full_prompt = CommonBuilder.context_prefix(opts) .. prompt
  end

  local cmd = { grok_path }

  table.insert(cmd, "--single=" .. full_prompt)
  table.insert(cmd, "--output-format")
  table.insert(cmd, "streaming-json")

  local model = NonClaudeModel.resolve(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  if session_id then
    table.insert(cmd, "--resume")
    table.insert(cmd, session_id)
    if opts._is_fork then
      table.insert(cmd, "--fork-session")
    end
  end

  if opts.lightweight then
    append_lightweight_flags(cmd)
  elseif opts.permission_mode then
    local mode = GROK_PERMISSION_MODE_FALLBACK[opts.permission_mode] or opts.permission_mode
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, mode)
  end

  if opts.cwd and opts.cwd ~= "" then
    table.insert(cmd, "--cwd")
    table.insert(cmd, opts.cwd)
  end

  local rules = build_rules(opts, config)
  if rules then
    table.insert(cmd, "--rules")
    table.insert(cmd, rules)
  end

  return cmd
end

return M
