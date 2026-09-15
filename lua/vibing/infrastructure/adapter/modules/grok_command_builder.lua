--- The parts of the `grok --single` argv a flag table cannot express (ADR 009 P2).
---
--- The request itself is `request` in `backends/grok.lua`; `request_builder.lua` resolves the
--- shared values. What stays here is the binary resolution -- configurable, and sniffed for the
--- official CLI -- plus the `--rules` block and the `--cwd` flag. `build()` remains as the
--- historical entry point.
--- @module vibing.infrastructure.adapter.modules.grok_command_builder

local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")
local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")
local GrokLightweight = require("vibing.infrastructure.adapter.modules.grok_lightweight")
local worktree_constants = require("vibing.core.constants.worktree")

local M = {}

--- Grok's --permission-mode only accepts default/dontAsk/acceptEdits/bypassPermissions/plan.
--- vibing's "auto" mode (Claude's background safety classifier) has no Grok equivalent, so it
--- falls back to asking for confirmation instead of forwarding an unsupported value.
--- @type table<string, string>
M.PERMISSION_MODE_FALLBACK = {
  auto = "default",
}

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
      .. "Install from https://x.ai/cli or set backends.grok.executable to the official binary path."
  )
end

--- Whether a cached path still points at something, for the cases where we can tell.
---
--- The cached path is confirmed rather than trusted, for the reason
--- `command_builder_common.binary_resolver` states (#593): an uninstall or a relocating reinstall
--- leaves it pointing at nothing, and handing it back skips both errors below and turns into a raw
--- ENOENT out of vim.system. Grok keeps its own cache because it resolves a *configurable*
--- executable and sniffs it for officialness, neither of which the shared resolver does.
---
--- What is skipped is a **bare command name**: no `/` at all. `backends.grok.executable` accepts one
--- (`vim.fn.executable("grok")` searches PATH for it), and `fs_stat` would resolve that against
--- Neovim's cwd and answer nil forever -- defeating the cache on every request, which costs far
--- more than the lookup: the fallthrough re-runs `ensure_official_grok`, and that blocks the main
--- loop on a `grok --version` subprocess. Those keep the pre-#593 behaviour.
---
--- Anything with a `/` in it is a location, relative ones included, and is checked. `fs_stat`
--- resolves a relative path against Neovim's cwd -- which is the same basis `vim.fn.executable`
--- used to accept it in the first place, so the two agree. Gating on "starts with `/`" instead
--- would leave `./bin/grok` permanently unchecked and #593 alive for it.
---
--- A Windows path written with backslashes only (`C:\bin\grok.exe`, a UNC share) reads as a bare
--- name here and goes unchecked, i.e. keeps the pre-#593 behaviour. Not worth parsing drive
--- letters for while the rest of the process handling (`pkill`, `sh -c`) is POSIX-only anyway.
---
--- @param path string
--- @return boolean
local function still_installed(path)
  if not path:find("/", 1, true) then
    return true
  end
  return vim.uv.fs_stat(path) ~= nil
end

--- Resolve path to the grok binary
--- @param config Vibing.Config
--- @return string
local function resolve_grok_path(config)
  local configured = vim.tbl_get(config or {}, "backends", "grok", "executable")

  if cached_grok_path and cached_configured_executable == configured and still_installed(cached_grok_path) then
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
          .. "(curl -fsSL https://x.ai/cli/install.sh | bash) or set backends.grok.executable."
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

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec that
--- wants to exercise the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  cached_grok_path = nil
  cached_configured_executable = nil
end

--- The binary, for the request spec: configurable and sniffed, so not the shared PATH lookup.
--- @type { resolve: fun(config: Vibing.Config): string, reset: fun() }
M.BINARY = { resolve = resolve_grok_path, reset = M._reset_path_cache }

--- `--rules`, or nothing when there is nothing to say.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.rules_args(ctx)
  local rules = build_rules(ctx.opts, ctx.config)
  if rules then
    return { "--rules", rules }
  end
  return {}
end

--- `--cwd`. For a lightweight call this is the scratch directory, which is how grok is kept from
--- reading the project's AGENTS.md/CLAUDE.md and its `.grok/hooks/`: there is no flag for either,
--- but `--cwd` decides which project it is looking at.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.cwd_args(ctx)
  local cwd = GrokLightweight.resolve_cwd(ctx.opts)
  if cwd and cwd ~= "" then
    return { "--cwd", cwd }
  end
  return {}
end

--- Build the `grok --single=<prompt>` command array from the request spec in `backends/grok.lua`.
---
--- `--single=<value>` (one argv token) rather than `-p <value>` so hyphen-leading prompts are not
--- misparsed as flags by clap.
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config)
  return RequestBuilder.build(
    require("vibing.infrastructure.adapter.backends.grok").request,
    prompt,
    opts or {},
    session_id,
    config or {}
  )
end

return M
