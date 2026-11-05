--- RPC handler for the question a CLI's own gate asks a human, through `--permission-prompt-tool`.
---
--- **This is not the PreToolUse hook, and it must not answer for vibing's permissions.** Measured on
--- claude 2.1.309: the hook runs first and its `defer` is what lets the call reach the CLI's gate;
--- the gate then asks a human about things no `permissions.allow` entry, settings allow rule or hook
--- `allow` can pass — an edit inside a `--plugin-dir` directory ("which is a sensitive file") is the
--- case that motivated this. So what arrives here is the question vibing's own verdict could not
--- answer, and the prompt it opens carries `kind = "native"`: `approval_decision` routes that kind
--- to a module with no access to `update_session_permissions`, exactly as for codex's own approvals
--- (#861).
---
--- #789 rejected this channel as a replacement for the hook, because the gate answers ahead of it
--- for anything its allowlist or classifier passes and vibing's `permissions.ask` would lose its
--- say. That objection does not reach this use: the hook still decides first, and this only answers
--- what the gate would otherwise refuse with nobody to ask.
---
--- The reply is withheld (`server.DEFERRED`) until a human answers, and `pending_native_approvals`
--- holds the obligation and its exits. The MCP server turns the decision into the CLI's own shape.
--- @module vibing.infrastructure.rpc.handlers.permission_prompt

local HookScope = require("vibing.infrastructure.rpc.hook_scope")
local Identity = require("vibing.core.utils.identity")
local NativeApprovals = require("vibing.infrastructure.rpc.pending_native_approvals")

local M = {}

M.KIND = NativeApprovals.KIND

--- What every exit that is not a human answer replies with.
M.REFUSAL = {
  decision = "deny",
  message = "vibing.nvim refused this call because nobody answered the approval prompt. "
    .. "Do not retry it immediately.",
}

--- @type Vibing.CodexDecisionOption[]
M.OPTIONS = {
  {
    value = "allow_once",
    label = "allow_once - Let the CLI run this one call it asked about",
    raw = { decision = "allow" },
    is_allow = true,
  },
  {
    value = "deny_once",
    label = "deny_once - Refuse this one call; the turn carries on",
    raw = { decision = "deny", message = "The user denied this call in vibing.nvim. Use a different approach." },
    is_allow = false,
  },
}

--- The id this prompt is known by in the chat. Prefixed so it can never collide with a hook's
--- `<epoch>-<pid>-<random>` or a codex `codex-<process>-<rpc>` id, which `blocked_for_request` relies
--- on; both halves survive the `[^%s]+` the buffer marker is read back with.
--- @param process_id string
--- @param tool_use_id string|nil
--- @return string
function M.request_id(process_id, tool_use_id)
  local suffix = type(tool_use_id) == "string" and tool_use_id:gsub(Identity.HOOK_SAFE_CLASS, "") or ""
  if suffix == "" then
    suffix = Identity.new_request_id()
  end
  return string.format("prompt-%s-%s", process_id, suffix)
end

--- @param message string
--- @return table
local function refused(message)
  return { decision = "deny", message = message }
end

--- @param params {process_id: string?, tool_name: string?, input: table?, tool_use_id: string?}|nil
--- @param respond fun(result: table)
--- @return table result the immediate answer, or `server.DEFERRED`
function M.permission_prompt(params, respond)
  params = params or {}
  local tool = params.tool_name
  if type(tool) ~= "string" or tool == "" then
    return refused("vibing.nvim received a permission prompt with no tool name.")
  end
  local input = require("vibing.infrastructure.rpc.permission_prompt_request").describe(params.input)

  -- A guess is refused here where `permission.lua` accepts one: that path applies a chat's lists,
  -- this one draws a prompt, and an MCP server registered at user scope by an unrelated session
  -- names no process at all. Asking whichever chat happens to be streaming would show it a
  -- question from somewhere else.
  local scope = HookScope.of(params)
  local turn = not scope.guessed and scope.entry or nil
  local chat_bufnr = turn and turn.process and turn.process.chat_bufnr or nil
  -- Only a process spawned with `--permission-prompt-tool` has a gate that asks here. Everywhere
  -- else (another backend, or claude with the flag withheld) the tool is an ordinary auto-allowed
  -- vibing MCP tool, and the only caller is the model drawing a prompt no gate asked for.
  local asked_by_gate = turn and turn.process and type(turn.process.permission_prompt_tool) == "string"
  if not (asked_by_gate and chat_bufnr and turn.can_wait_for_native_approval and turn.on_approval_required) then
    return refused(
      string.format("vibing.nvim had no chat able to wait for an answer about %s, so it was refused.", tool)
    )
  end

  local request_id = M.request_id(scope.process_id, params.tool_use_id)

  -- Register before drawing: the registry arms the wait limit, so anything that throws below still
  -- ends in a decision reaching the CLI rather than a tool call held to the MCP ceiling.
  NativeApprovals.open({
    request_id = request_id,
    chat_bufnr = chat_bufnr,
    turn_id = turn.turn_id,
    tool = tool,
    refusal = M.REFUSAL,
    respond = respond,
    on_timeout = NativeApprovals.expire_in_chat,
  })

  local ok, err = pcall(turn.on_approval_required, tool, input, M.OPTIONS, request_id, true, M.KIND)
  if not ok then
    vim.notify(
      string.format("[vibing] could not draw the permission prompt for %s: %s", tool, tostring(err)),
      vim.log.levels.ERROR
    )
  end

  require("vibing.application.chat.completion_notifier").on_approval_waiting(chat_bufnr, request_id)
  return require("vibing.infrastructure.rpc.server").DEFERRED
end

return M
