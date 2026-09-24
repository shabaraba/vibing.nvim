--- Argv for the Pi coding agent, for the parts the declarative request spec cannot state.
--- @module vibing.infrastructure.adapter.modules.pi_command_builder

local Notify = require("vibing.core.utils.notify")
local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")

local M = {}

--- The read-only subset of Pi's built-in tools, by Pi's own names (`pi --help`).
---
--- `--tools` is an allowlist over built-in, extension and custom tools alike, so naming these is
--- how a Pi run is made unable to change anything.
--- @type string
local READ_ONLY_TOOLS = "read,grep,find,ls"

--- The same, plus the two web tools `pi-extension/src/index.ts` registers.
---
--- `plan` is "do not change anything", not "do not look anything up" — claude's plan mode allows
--- `WebFetch` and `WebSearch` for the same reason, and a plan written without being able to read
--- the linked issue is the worse failure. The list above deliberately does **not** grow to match:
--- that one is for a turn whose permission gate failed to load, where `read` plus an outbound URL
--- is an exfiltration channel with nothing looking at it, and `read` alone is not.
--- @type string
local PLAN_TOOLS = READ_ONLY_TOOLS .. ",web_fetch,web_search"

--- What a lightweight call is fenced with (`core/types.lua`: no tools, no project config, no user
--- MCP servers, no hooks, `utility_model`).
---
--- `--no-tools` is the whole of the first clause: Pi documents it as disabling built-in *and*
--- extension tools, so unlike copilot there is no empty-list-is-ignored hazard to work around. The
--- rest of the list is the project-config half — `AGENTS.md`/`CLAUDE.md` discovery, skills, prompt
--- templates and any extension the user installed — and `--no-approve` refuses project-local files
--- outright rather than trusting them for a call the user did not make. `--no-session` keeps a
--- title generation from leaving a session file behind.
--- @type string[]
M.LIGHTWEIGHT_ARGS = {
  "--no-tools",
  "--no-context-files",
  "--no-skills",
  "--no-extensions",
  "--no-prompt-templates",
  "--no-approve",
  "--no-session",
}

local MISSING_MESSAGE = "Pi CLI not found. Install it with `curl -fsSL https://pi.dev/install.sh | sh`, "
  .. "or set backends.pi.executable to its path."

--- PATH lookup for the default `executable = "auto"`, with the shared cache — which re-resolves
--- when the binary it remembered is no longer on disk, the case a plain memo gets wrong after a
--- package upgrade moves it.
local auto_resolver = require("vibing.infrastructure.adapter.modules.command_builder_common").binary_resolver(
  "pi",
  MISSING_MESSAGE
)

--- @param config Vibing.Config
--- @return string
local function resolve_pi_path(config)
  local configured = (((config or {}).backends or {}).pi or {}).executable or "auto"
  if configured == "auto" or configured == "" then
    return auto_resolver.resolve()
  end
  -- Used as given and never silently reset: a user who named a path wants that binary, and falling
  -- back to PATH would run a different one without saying so. No caching to do — the value is
  -- already the answer.
  return configured
end

--- Test seam, discovered by `tests/helpers/adapter_stream.lua`.
function M._reset_path_cache()
  auto_resolver.reset()
end

--- @type Vibing.RequestBinary
M.BINARY = { resolve = resolve_pi_path, reset = M._reset_path_cache }

--- `--provider <name>`, when one is configured.
---
--- Pi resolves a bare `--model` across every configured provider, which for a local endpoint is
--- usually what you want; naming the provider is how a user pins a model id that also exists
--- upstream. Empty means "let Pi choose", which is Pi's own default.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.provider_args(ctx)
  local provider = (((ctx.config or {}).backends or {}).pi or {}).provider
  if type(provider) ~= "string" or provider == "" then
    return {}
  end
  return { "--provider", provider }
end

--- Which session this run continues, and whether it forks.
---
--- An `extra` rather than the `resume` primitive because Pi's fork is a *different flag* carrying
--- the same id (`--fork <id>`), not an extra flag alongside `--session-id`. The primitive's `fork`
--- modifier appends, which here would name the session twice and ask Pi to both continue and fork
--- it.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.session_args(ctx)
  local session_id = ctx.session_id
  if not session_id or session_id == "" then
    return {}
  end
  if ctx.opts and ctx.opts._is_fork then
    return { "--fork", session_id }
  end
  return { "--session-id", session_id }
end

--- Which tools this run may have.
---
--- Pi has no permission modes, no sandbox and no approval prompt: the gate is entirely
--- vibing.nvim's, through the extension named by `ctx.hook_arg`. So this function answers the only
--- question Pi's own argv can express — *which tools exist at all* — for the two cases where the
--- answer is not "all of them".
---
--- **`plan`.** Pi has no concept of it. Every other backend maps the mode onto something its CLI
--- understands; here the only way to make "do not change anything" true is to take the writing
--- tools away. Left unmapped, `plan` would be an ordinary editing session with a reassuring label,
--- which is worse than not offering the mode at all.
---
--- **No gate.** `cli_adapter` warns and carries on when a transport fails to install, which is the
--- right trade for a CLI that still has its own approval gate underneath. Pi has none, so the same
--- turn would run `bash` and `write` with the user's `permissions.deny` rules silently inert. It
--- degrades to the read-only set instead — visible to the model, which loses the tools, and
--- announced once to the user.
---
--- bypassPermissions is the one exception, and deliberately: there the user has said "do not gate
--- me", so there are no rules being silently skipped and overriding them would be us ignoring an
--- explicit instruction. What is lost there is the git-snapshot baseline the same round trip takes,
--- so the warning says that instead.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.permission_args(ctx)
  local mode = (ctx.opts or {}).permission_mode or "default"

  if not ctx.hook_arg then
    if mode == "bypassPermissions" then
      Notify.warn_once(
        "pi_bridge_missing_bypass",
        "Pi is running without vibing.nvim's permission bridge, so this turn produces no "
          .. "### Modified Files and no `gd` diff. Run ./build.sh to build pi-extension/."
      )
      return {}
    end
    Notify.warn_once(
      "pi_bridge_missing",
      "Pi is running without vibing.nvim's permission bridge, so it has been restricted to "
        .. "read-only tools: unrestricted, it does not ask before running bash and your "
        .. "permissions rules would not apply to it. Run ./build.sh to build pi-extension/."
    )
    return { "--tools", READ_ONLY_TOOLS }
  end

  if mode == "plan" then
    return { "--tools", PLAN_TOOLS }
  end
  return {}
end

--- Build the argv.
--- @param prompt string
--- @param opts Vibing.AdapterOpts
--- @param session_id string|nil
--- @param config Vibing.Config
--- @param extension_path string|nil what the `extension_file` transport resolved; nil degrades the
---   run to read-only tools (`permission_args`) rather than running ungated
--- @return string[]
function M.build(prompt, opts, session_id, config, extension_path)
  return RequestBuilder.build(
    require("vibing.infrastructure.adapter.backends.pi").request,
    prompt,
    opts,
    session_id,
    config,
    extension_path
  )
end

--- Environment for the extension running inside Pi.
---
--- The bridge needs two things vibing.nvim knows and Pi does not: where the shared hook script is,
--- and how long it may wait before failing closed. Both travel in the environment rather than in a
--- generated file, which is what lets `pi_settings_generator` write nothing per instance.
---
--- `VIBING_PI_WEB_SEARCH` chooses the `web_search` backend. Only the provider *name* travels: the
--- API keys stay in the user's own environment (`BRAVE_SEARCH_API_KEY`, `TAVILY_API_KEY`,
--- `SEARXNG_URL`), because a credential in `setup()` is a credential in a dotfiles repository.
---
--- Nothing is set on the lightweight path, which passes `--no-extensions` and so loads none of it.
--- @param env table<string, string>
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
function M.apply_env(env, opts, config)
  if (opts or {}).lightweight then
    return
  end
  local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
  local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")
  env.VIBING_PI_HOOK_SCRIPT = SettingsGenerator.get_hook_script_path()
  env.VIBING_PI_HOOK_TIMEOUT_SEC = tostring(WaitBudget.cli_timeout_sec())

  local web_search = (((config or {}).backends or {}).pi or {}).web_search
  env.VIBING_PI_WEB_SEARCH = type(web_search) == "string" and web_search ~= "" and web_search or "auto"
end

return M
