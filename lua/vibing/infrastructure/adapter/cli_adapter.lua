--- The one CLI adapter. A backend is a descriptor (`backends/<id>.lua`); this module is the
--- `stream()` every backend used to carry its own copy of.
---
--- Before ADR 009 there were four adapter files, and their `stream()` bodies differed in seven
--- points: which hook generator ran before the build, what the command builder's fifth argument
--- was, the child environment, whether `chat_bufnr` was registered, whether a tool vocabulary was
--- handed to the permission handler, whether stderr was filtered, and whether stdin was closed.
--- Each of those is one field of the descriptor, so the ~200 lines around them exist once.
---
--- The descriptor contract is `Vibing.BackendDescriptor` below. Everything a backend has to say
--- about itself goes there; nothing in this file names a backend.
--- @module vibing.infrastructure.adapter.cli_adapter

local Base = require("vibing.infrastructure.adapter.base")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local Identity = require("vibing.core.utils.identity")
local RpcEnvironment = require("vibing.infrastructure.adapter.modules.rpc_environment")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
local RateLimitDetector = require("vibing.infrastructure.adapter.modules.rate_limit_detector")
local ProcessModel = require("vibing.infrastructure.adapter.modules.process_model")
local DuplexStream = require("vibing.infrastructure.adapter.modules.duplex_stream")
local HookTransports = require("vibing.infrastructure.hooks.transports")
local PluginScaffold = require("vibing.infrastructure.plugins.scaffold")

---@class Vibing.BackendDescriptor
---@field id string The agent id (`claude`, `codex`, ...). `adapter.name` is `<id>_cli`.
---@field features table<string, boolean> What `supports()` answers.
---@field build fun(prompt: string, opts: Vibing.AdapterOpts, session_id: string?, config: Vibing.Config, hook_arg: any): string[]
---  Builds the argv. Raises when the binary is missing; the raise is reported through `on_done`.
---@field event_processor { processLine: fun(line: string, context: table): boolean }
---  Turns one stdout line into chunk/tool events on the event context.
---@field hook? Vibing.HookSpec How the PreToolUse hook reaches this CLI (`hooks/transports.lua`).
---  Installed before `build`, which receives what the transport returned (a settings path, an
---  argv fragment, a plugin dir). A failed installation warns and the turn runs ungated -- the
---  alternative, registering a hook nothing can run, is what hangs codex.
---@field seeds_project_plugins? boolean Seed `.vibing/plugins/` in the project on the first real
---  request (`plugins/scaffold.lua`), alongside the hook settings: both are "this project is now
---  using vibing.nvim" side effects, and this is the one place a real request passes through.
---@field resolve_cwd? fun(opts: Vibing.AdapterOpts): string? The process cwd, when it is not
---  simply `opts.cwd` (a lightweight grok call runs from a scratch directory).
---@field apply_env? fun(env: table<string, string>, opts: Vibing.AdapterOpts, config: Vibing.Config)
---  Backend-specific edits to the child environment. Runs before the `VIBING_*` binding, so a
---  backend can never override those.
---@field event_context_fields? fun(): table Extra fields on the event context (claude pre-creates
---  its token accumulator and `cliInfo` so mid-stream events always have somewhere to land).
---@field vocabulary? table Tool-name/payload normalisation handed to the permission handler.
---@field register_chat_bufnr? boolean Whether `nvim_ask_user_question` can route back to this
---  stream's chat buffer. Only the backends whose MCP route is wired say yes.
---@field stdin? string What to hand the child on stdin; `""` closes it so a CLI that reads stdin
---  when no prompt argument is present does not wait on a terminal that isn't there.
---@field stderr_filter? fun(data: string): string? Drops or rewrites a stderr chunk before it is
---  recorded. Returning nil or "" drops it.
---@field after_spawn? fun(cmd: string[], cwd: string, opts: Vibing.AdapterOpts, config: Vibing.Config)
---  Runs once the process exists (codex fires its provider probe here).
---@field on_project_open? fun(project_root: string, config: Vibing.Config) Files this backend keeps
---  in a project's `.vibing/`, written when the directory is created (`file_manager`).
---@field on_setup? fun(cwd: string, config: Vibing.Config) Backfill for projects whose `.vibing/`
---  predates those files; runs from `setup()` and must not create `.vibing/` where there is none.
---@field clear_caches? fun() Memoised state to drop on `:VibingReloadCommands`.
---@field process? "oneshot"|"duplex" The most capable process model this backend can run; absent
---  means `oneshot` only. Not the default — that is `oneshot` for everyone, and a chat opts in
---  through `backends.<id>.process` or its own frontmatter (`process_model.lua`). Named `process`
---  rather than `transport` because `Vibing.HookSpec.transport` already owns that word.

local M = {}

--- Shared with execute()'s own wait, so the two cannot drift apart.
local INITIAL_RESPONSE_TIMEOUT_MS = CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS

--- One adapter class per descriptor id, so the compatibility shims (`claude_cli.lua` etc.) and
--- `factory.create` hand out the same class.
--- @type table<string, table>
local classes = {}

--- @param descriptor Vibing.BackendDescriptor
--- @param opts Vibing.AdapterOpts
--- @return string
local function resolve_cwd(descriptor, opts)
  local cwd = descriptor.resolve_cwd and descriptor.resolve_cwd(opts) or opts.cwd
  if cwd and cwd ~= "" then
    return cwd
  end
  return vim.fn.getcwd()
end

--- @param descriptor Vibing.BackendDescriptor
--- @param error_output string[]
--- @return fun(err: any, data: string?)
local function stderr_handler(descriptor, error_output)
  if not descriptor.stderr_filter then
    return StreamHandler.create_stderr_handler(error_output)
  end
  local filter = descriptor.stderr_filter
  return function(_, data)
    if data then
      local cleaned = filter(data)
      if cleaned and cleaned ~= "" then
        table.insert(error_output, cleaned)
      end
    end
  end
end

--- Build the adapter class for one descriptor.
--- @param descriptor Vibing.BackendDescriptor
--- @return table class with `new()`, `stream()` and everything `cli_runtime.install` provides
function M.define(descriptor)
  assert(type(descriptor) == "table" and type(descriptor.id) == "string", "descriptor needs an id")
  if classes[descriptor.id] then
    return classes[descriptor.id]
  end

  local Class = setmetatable({}, { __index = Base })
  Class.__index = Class
  Class.descriptor = descriptor

  CliRuntime.install(Class, descriptor.features or {})

  --- @param config Vibing.Config
  function Class:new(config)
    local instance = Base.new(self, config)
    setmetatable(instance, Class)
    instance.name = descriptor.id .. "_cli"
    instance._processes = {}
    instance._session_manager = SessionManagerModule.new()
    return instance
  end

  --- @param prompt string
  --- @param opts Vibing.AdapterOpts
  --- @param on_chunk fun(chunk: string, turn_id: string)
  --- @param on_done fun(response: Vibing.Response)
  --- @return string turn_id the turn
  --- @return string process_id the CLI process serving it
  function Class:stream(prompt, opts, on_chunk, on_done)
    opts = opts or {}

    -- Resolved once, here, and written back onto this turn's opts under a private name: the request
    -- spec branches on it (`--input-format`, and whether the prompt goes into the argv at all), and
    -- re-deriving it there would let the argv and the transport disagree. `opts.process` stays as
    -- the chat wrote it.
    local process_model = ProcessModel.resolve(descriptor, opts, self.config)
    opts._process_model = process_model
    local is_duplex = process_model == ProcessModel.DUPLEX

    local debug_mode = vim.g.vibing_debug_stream
    -- Two identities, minted together because one process serves one turn here
    -- (`handbook/architecture/processes-and-turns.md`).
    local ids = {
      turn_id = Identity.new_turn_id(),
      process_id = Identity.new_process_id(),
    }
    local session_id = opts._session_id
    local tag = "[vibing:" .. descriptor.id .. "]"

    if debug_mode then
      vim.notify(
        string.format(
          "%s Starting stream: turn_id=%s, process_id=%s, session_id=%s",
          tag,
          ids.turn_id,
          ids.process_id,
          session_id or "new"
        ),
        vim.log.levels.INFO
      )
    end

    local cwd = resolve_cwd(descriptor, opts)

    if descriptor.seeds_project_plugins and not opts.lightweight then
      pcall(PluginScaffold.ensure, cwd, self.config)
    end

    -- The hook is registered before the argv is built because some transports are referenced
    -- from the argv (a settings path, a `-c` fragment, a plugin dir).
    local hook_arg = nil
    if descriptor.hook and HookTransports.wanted(descriptor.hook, opts) then
      local ok, result = pcall(HookTransports.install, descriptor.hook, cwd)
      if ok then
        hook_arg = result
      else
        vim.notify(
          string.format(
            "%s Failed to install the PreToolUse hook, so this turn is not gated by vibing.nvim: %s",
            tag,
            tostring(result)
          ),
          vim.log.levels.WARN
        )
      end
    end

    -- The builder raises when the binary is missing. send_message.lua does not wrap stream() in
    -- pcall, so without this the chat buffer would show a raw Lua stack trace instead of an
    -- actionable message.
    local build_ok, cmd = pcall(descriptor.build, prompt, opts, session_id, self.config, hook_arg)
    if not build_ok then
      CliRuntime.report_build_failure(ids, cmd, on_done)
      return ids.turn_id, ids.process_id
    end

    local output = {}
    local error_output = {}

    local received_first_response = false
    local timeout_timer = nil
    local completed = false

    local function cancel_timeout()
      received_first_response = true
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end
    end

    local event_context = {
      sessionManager = self._session_manager,
      turnId = ids.turn_id,
      -- The session a `{kind = "session"}` event names belongs to the process that reported it, so
      -- the renderer stores it under this and not under the turn.
      processId = ids.process_id,
      opts = opts,
      output = output,
      errorOutput = error_output,
      onFirstResponse = cancel_timeout,
      onChunk = function(chunk)
        cancel_timeout()
        on_chunk(chunk, ids.turn_id)
      end,
    }
    if descriptor.event_context_fields then
      for key, value in pairs(descriptor.event_context_fields()) do
        event_context[key] = value
      end
    end

    local env = vim.fn.environ()
    -- Backend edits first, so a variable the user declared reads exactly like one they exported:
    -- the `VIBING_*` binding below still overwrites it.
    if descriptor.apply_env then
      descriptor.apply_env(env, opts, self.config)
    end
    -- The CLI forwards this environment to the MCP servers it starts, so the numeric port stays
    -- out of the cached prompt (#730).
    RpcEnvironment.bind(env)
    -- The process, not the turn: an environment variable is fixed when the child is spawned, so a
    -- resident process (#774) could not carry a per-turn value here even in principle. The hook
    -- names this and `rpc/hook_scope.lua` resolves the turn in-editor, which is what keeps
    -- concurrent chats from cross-wiring each other's approval UI.
    env.VIBING_PROCESS_ID = ids.process_id

    -- The permission handler stays ignorant of which backend it is serving; it just calls whatever
    -- vocabulary it was handed (#516). Registered for a lightweight call too: `cancel()` and the
    -- exit path resolve the turn through these entries, not only the hook.
    --
    -- Called at the top of *every* turn, which is what
    -- `processes-and-turns.md` → "What is still owed" asks a resident transport for: turn N+1 must
    -- not run under turn N's `permission_mode` and ignore the allow entry an approval just made.
    --
    -- `_can_wait_for_approval` travels the same way and for the same reason: whether an `ask` may
    -- block the hook instead of killing the process is a property of *this* backend — its measured
    -- floor against the currently configured wait, **and** whether it registers `chat_bufnr` just
    -- below, since the waiting path has no other way to name the chat that answers. The whole
    -- descriptor goes in rather than `descriptor.hook`, because that second half does not live on
    -- the hook. The handler must not be the place that knows which backend it is
    -- (`.claude/rules/architecture.md`). Resolved per turn, so raising
    -- `permissions.approval_wait_sec` past a floor turns waiting off on the next send.
    local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")
    perm_handler.set_active_opts(
      ids.turn_id,
      vim.tbl_extend("force", opts, {
        _tool_vocabulary = descriptor.vocabulary,
        _can_wait_for_approval = HookTransports.can_wait_for_approval(descriptor),
      })
    )

    --- Whatever the transport has to do to the *process* once its turn is over. Runs between the
    --- turn's own teardown and `on_done`, so the ordering the oneshot path has always had —
    --- registries emptied before anyone is told the turn ended — is the same on both.
    --- @type fun()|nil
    local close_process = nil

    --- Everything a turn owes on its way out, whether or not the process serving it also ends.
    local function finish(response)
      if completed then
        return
      end
      completed = true
      -- Turn first: `close` clears the process entry's `active_turn_id`, and unregistering the
      -- process first would leave nothing for it to clear it on.
      TurnRegistry.close(ids.turn_id)
      if close_process then
        close_process()
      end
      perm_handler.clear_active_opts(ids.turn_id)
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end

      RateLimitDetector.attach(response, ids.turn_id, event_context)

      -- Attached even on a failed turn: the requests it made were still paid for, and a turn that
      -- died at 600k is exactly the one worth reporting. A backend whose stream reports no usage
      -- leaves both nil.
      response._token_usage = event_context.tokenUsage
      response._cli_info = event_context.cliInfo

      on_done(response)
    end

    if is_duplex then
      return DuplexStream.run({
        adapter = self,
        descriptor = descriptor,
        config = self.config,
        ids = ids,
        prompt = prompt,
        opts = opts,
        hook_arg = hook_arg,
        cwd = cwd,
        env = env,
        argv = cmd,
        event_context = event_context,
        finish = finish,
        tag = tag,
      })
    end

    -- Two registrations, because a process and a turn are two lifetimes. Under this transport they
    -- begin and end together, so both are torn down together below.
    local process = {
      process_id = ids.process_id,
      -- Only where the nvim_ask_user_question route is wired: registering a value nothing
      -- consumes would only look like a working route (see features.md → AskUserQuestion).
      chat_bufnr = descriptor.register_chat_bufnr and opts.chat_bufnr or nil,
      session_id = opts._session_id,
      adapter = self,
    }
    ProcessRegistry.register(process)
    TurnRegistry.open({
      turn_id = ids.turn_id,
      process = process,
      worktree_root = opts._worktree_root,
      on_insert_choices = opts.on_insert_choices,
      on_approval_required = opts.on_approval_required,
    })
    close_process = function()
      ProcessRegistry.unregister(ids.process_id)
    end

    local started = CliRuntime.spawn(self._processes, ids, cmd, {
      text = true,
      stdin = descriptor.stdin,
      cwd = cwd,
      env = env,
      stdout = StreamHandler.create_stdout_handler(descriptor.event_processor, event_context, function()
        return self._processes[ids.process_id] == nil
      end),
      stderr = stderr_handler(descriptor, error_output),
    }, StreamHandler.create_exit_handler(ids, self._processes, output, error_output, finish, function()
      return event_context.resultErrors
    end), finish)

    if not started then
      return ids.turn_id, ids.process_id
    end

    if descriptor.after_spawn then
      descriptor.after_spawn(cmd, cwd, opts, self.config)
    end

    if debug_mode then
      local process = self._processes[ids.process_id]
      local pid = process and process.pid or "unknown"
      vim.notify(string.format("%s Process started: pid=%s", tag, tostring(pid)), vim.log.levels.INFO)
      vim.notify(string.format("%s Command: %s", tag, table.concat(cmd, " "):sub(1, 200)), vim.log.levels.DEBUG)
    end

    -- Session corruption detection: a resumed session that never answers is killed and reset.
    if session_id then
      timeout_timer = vim.fn.timer_start(INITIAL_RESPONSE_TIMEOUT_MS, function()
        if not received_first_response and not completed and self._processes[ids.process_id] then
          vim.schedule(function()
            if not completed then
              vim.notify(
                "[vibing] Session resume timeout - killing hung process and resetting session",
                vim.log.levels.WARN
              )
              self:cancel(ids.process_id)
              finish({
                error = "Session resume timeout",
                _session_corrupted = true,
                _old_session_id = session_id,
                -- Without this, send_message's staleness check is skipped entirely: a timeout that
                -- fires after the user cancelled and sent something new would be treated as the
                -- new request's result and reset its session id.
                _turn_id = ids.turn_id,
                _process_id = ids.process_id,
              })
            end
          end)
        end
      end)
    end

    return ids.turn_id, ids.process_id
  end

  classes[descriptor.id] = Class
  return Class
end

--- The adapter class for a registered agent id.
--- @param agent_id string
--- @return table
function M.for_agent(agent_id)
  local Agents = require("vibing.core.constants.agents")
  return M.define(require(Agents.get(agent_id).descriptor_module))
end

return M
