--- Builds a CLI's argv from the `request` table of a backend descriptor (ADR 009 P2).
---
--- A request is an ordered list of parts. Most parts are data -- a flag name and which shared
--- value goes after it -- and the values themselves (which model, which effort, whether to resume)
--- are resolved here, once, so a rule such as "a lightweight call uses `utility_model`" cannot be
--- fixed on one backend and stay broken on another (#537). What a flag table cannot express -- a
--- system prompt composed from a dozen sources, a permission mode mapped onto a sandbox profile --
--- is an `extra` part: a function that returns an argv fragment, named in the descriptor so the
--- procedural parts of a backend are listed rather than buried.
---
--- Order matters and is the descriptor's to state: the CLIs disagree on where the prompt goes,
--- whether `resume` is a subcommand, and which flags a resumed session still accepts.
--- @module vibing.infrastructure.adapter.modules.request_builder

local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")
local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local ReasoningEffort = require("vibing.infrastructure.adapter.modules.reasoning_effort")

---@class Vibing.RequestContext
---@field prompt string the user's message
---@field opts Vibing.AdapterOpts
---@field session_id string?
---@field config Vibing.Config
---@field hook_arg any what the hook transport returned, if a hook was installed
---@field cmd string[] the argv so far (extras may read it, never edit it)

---@alias Vibing.RequestCondition
---| "lightweight"            # `opts.lightweight`
---| "session"                # resuming a session
---| "hook_arg"               # a hook was installed for this turn
---| { config: string }       # a truthy value at that dotted path in the config

---@class Vibing.RequestPart
---@field kind "args"|"model"|"effort"|"resume"|"hook_arg"|"permission_mode"|"prompt"|"extra"
---@field when? Vibing.RequestCondition|Vibing.RequestCondition[] all must hold
---@field unless? Vibing.RequestCondition|Vibing.RequestCondition[] none may hold
---@field flag? string `--flag value`
---@field flag_eq? string `--flag=value`, one argv token
---@field names? "claude"|"native" model: claude's short names pass through; native drops them
---@field config? string effort: a `-c key=%s` override instead of a flag
---@field fork? string resume: the flag added when `opts._is_fork`
---@field subcommand? string resume: `<subcommand> <session_id>` rather than a flag
---@field map? table<string, string> permission_mode: values to translate before passing
---@field terminator? string prompt: an end-of-options marker placed before the prompt
---@field language_prefix? boolean prompt: prepend the response-language sentence (for CLIs with
---  no system prompt channel; the others put it there)
---@field fn? fun(ctx: Vibing.RequestContext): string[]|nil extra: the argv fragment

---@class Vibing.RequestSpec
---@field binary { name: string, missing: string }|{ resolve: fun(config: Vibing.Config): string, reset: fun() }
---  A name looked up on PATH once and confirmed with `fs_stat` (`command_builder_common`), or a
---  backend's own resolver when the binary is configurable.
---@field parts Vibing.RequestPart[]

local M = {}

--- One cached PATH lookup per named binary, shared by every spec naming it.
--- @type table<string, table>
local resolvers = {}

--- @param spec Vibing.RequestSpec
--- @return table `{ resolve, reset }`
local function resolver_for(spec)
  local binary = spec.binary
  if binary.resolve then
    return binary
  end
  if not resolvers[binary.name] then
    resolvers[binary.name] = CommonBuilder.binary_resolver(binary.name, binary.missing)
  end
  return resolvers[binary.name]
end

--- Forget the resolved binary of a spec. Test seam: the cache is process-wide, so a spec that
--- wants the "CLI missing" path has to clear what an earlier spec resolved.
--- @param spec Vibing.RequestSpec
function M.reset_binary(spec)
  resolver_for(spec).reset()
end

--- @param condition Vibing.RequestCondition
--- @param ctx Vibing.RequestContext
--- @return boolean
local function holds(condition, ctx)
  if condition == "lightweight" then
    return ctx.opts.lightweight == true
  elseif condition == "session" then
    return ctx.session_id ~= nil
  elseif condition == "hook_arg" then
    return ctx.hook_arg ~= nil
  elseif type(condition) == "table" and condition.config then
    return vim.tbl_get(ctx.config or {}, unpack(vim.split(condition.config, ".", { plain = true }))) and true or false
  end
  error("unknown request condition " .. vim.inspect(condition))
end

--- @param conditions Vibing.RequestCondition|Vibing.RequestCondition[]|nil
--- @return Vibing.RequestCondition[]
local function as_list(conditions)
  if conditions == nil then
    return {}
  end
  if type(conditions) == "table" and conditions.config == nil then
    return conditions
  end
  return { conditions }
end

--- @param part Vibing.RequestPart
--- @param ctx Vibing.RequestContext
--- @return boolean
local function applies(part, ctx)
  for _, condition in ipairs(as_list(part.when)) do
    if not holds(condition, ctx) then
      return false
    end
  end
  for _, condition in ipairs(as_list(part.unless)) do
    if holds(condition, ctx) then
      return false
    end
  end
  return true
end

--- Claude's own short names pass straight through; every other backend drops them.
--- @param part Vibing.RequestPart
--- @param ctx Vibing.RequestContext
--- @return string|nil
local function resolve_model(part, ctx)
  if part.names == "claude" then
    local agent = ctx.config.agent or {}
    if ctx.opts.lightweight then
      return agent.utility_model or "sonnet"
    end
    return ctx.opts.model or agent.default_model
  end
  return NonClaudeModel.resolve(ctx.opts, ctx.config)
end

--- The prompt with the pieces every backend prepends: the `@file:` context on a new session and,
--- for a CLI with no system prompt channel, the response-language sentence.
--- @param part Vibing.RequestPart
--- @param ctx Vibing.RequestContext
--- @return string
local function full_prompt(part, ctx)
  local prompt = ctx.prompt
  if not ctx.session_id then
    prompt = CommonBuilder.context_prefix(ctx.opts) .. prompt
  end
  if part.language_prefix then
    local language_instruction = CommonBuilder.language_instruction(ctx.opts, ctx.config)
    if language_instruction then
      prompt = language_instruction .. "\n\n" .. prompt
    end
  end
  return prompt
end

--- @param cmd string[]
--- @param part Vibing.RequestPart
--- @param value string|nil
local function push_flag(cmd, part, value)
  if value == nil then
    return
  end
  if part.flag_eq then
    table.insert(cmd, part.flag_eq .. value)
  elseif part.flag then
    table.insert(cmd, part.flag)
    table.insert(cmd, value)
  else
    table.insert(cmd, value)
  end
end

local kinds = {}

kinds.args = function(cmd, part)
  for _, arg in ipairs(part) do
    table.insert(cmd, arg)
  end
end

kinds.model = function(cmd, part, ctx)
  push_flag(cmd, part, resolve_model(part, ctx))
end

kinds.effort = function(cmd, part, ctx)
  local effort = ReasoningEffort.resolve(ctx.opts, ctx.config)
  if effort == nil then
    return
  end
  if part.config then
    table.insert(cmd, "-c")
    table.insert(cmd, string.format(part.config, effort))
  else
    push_flag(cmd, part, effort)
  end
end

kinds.resume = function(cmd, part, ctx)
  if not ctx.session_id then
    return
  end
  if part.subcommand then
    table.insert(cmd, part.subcommand)
    table.insert(cmd, ctx.session_id)
  else
    push_flag(cmd, part, ctx.session_id)
  end
  if part.fork and ctx.opts._is_fork then
    table.insert(cmd, part.fork)
  end
end

--- A hook transport's return value: a path behind a flag, or an argv fragment appended verbatim.
kinds.hook_arg = function(cmd, part, ctx)
  local arg = ctx.hook_arg
  if arg == nil then
    return
  end
  if type(arg) == "table" then
    for _, value in ipairs(arg) do
      table.insert(cmd, value)
    end
  else
    push_flag(cmd, part, tostring(arg))
  end
end

kinds.permission_mode = function(cmd, part, ctx)
  local mode = ctx.opts.permission_mode
  if mode == nil then
    return
  end
  push_flag(cmd, part, (part.map and part.map[mode]) or mode)
end

kinds.prompt = function(cmd, part, ctx)
  if part.terminator then
    table.insert(cmd, part.terminator)
  end
  push_flag(cmd, part, full_prompt(part, ctx))
end

kinds.extra = function(cmd, part, ctx)
  for _, arg in ipairs(part.fn(ctx) or {}) do
    table.insert(cmd, arg)
  end
end

--- Build the argv.
--- @param spec Vibing.RequestSpec
--- @param prompt string
--- @param opts Vibing.AdapterOpts
--- @param session_id string|nil
--- @param config Vibing.Config
--- @param hook_arg any
--- @return string[]
function M.build(spec, prompt, opts, session_id, config, hook_arg)
  opts = opts or {}
  config = config or {}

  local binary = resolver_for(spec)
  local cmd = { binary.resolve(config) }
  local ctx = { prompt = prompt, opts = opts, session_id = session_id, config = config, hook_arg = hook_arg, cmd = cmd }

  for _, part in ipairs(spec.parts) do
    local apply = kinds[part.kind]
    if not apply then
      error("unknown request part kind " .. tostring(part.kind))
    end
    if applies(part, ctx) then
      apply(cmd, part, ctx)
    end
  end
  return cmd
end

--- The `build(prompt, opts, session_id, config, hook_arg)` a descriptor exposes, bound to its spec.
--- @param spec Vibing.RequestSpec
--- @return fun(prompt: string, opts: Vibing.AdapterOpts, session_id: string?, config: Vibing.Config, hook_arg: any): string[]
function M.builder(spec)
  return function(prompt, opts, session_id, config, hook_arg)
    return M.build(spec, prompt, opts, session_id, config, hook_arg)
  end
end

M._holds = holds

return M
