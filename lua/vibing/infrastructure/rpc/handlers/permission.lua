--- RPC handler for tool permission checks from pre-tool-use hook
--- @module vibing.infrastructure.rpc.handlers.permission

local can_use_tool_mod = require("vibing.infrastructure.permissions.can_use_tool")
local Config = require("vibing.config")

local M = {}

--- Session-level permission state (shared across all hook invocations)
--- @type {allowed: string[], denied: string[]}
local session_state = {
  allowed = {},
  denied = {},
}

--- Active chat frontmatter overrides, keyed by handle_id (set by stream start). A single shared
--- slot would let one chat buffer's opts silently apply to another's permission checks whenever
--- two chats stream concurrently (see ActiveStreamRegistry for the same class of bug).
--- @type table<string, table>
local active_opts_by_handle = {}

local APPROVAL_OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

--- Set active permission opts from chat frontmatter
--- @param handle_id string
--- @param opts table
function M.set_active_opts(handle_id, opts)
  active_opts_by_handle[handle_id] = opts
end

--- Clear active opts
--- @param handle_id string
function M.clear_active_opts(handle_id)
  active_opts_by_handle[handle_id] = nil
end

--- Resolve the frontmatter opts for a given handle_id. Falls back to the sole registered entry
--- when handle_id is nil/unmatched and exactly one chat is active (back-compat for hook
--- processes that don't yet pass VIBING_HANDLE_ID); returns nil rather than guessing when
--- multiple chats are active. Mirrors ActiveStreamRegistry.get()'s fallback.
--- @param handle_id string|nil
--- @return table|nil
local function get_active_opts(handle_id)
  if handle_id and active_opts_by_handle[handle_id] then
    return active_opts_by_handle[handle_id]
  end
  local only_handle_id, only_opts = next(active_opts_by_handle)
  if only_handle_id ~= nil and next(active_opts_by_handle, only_handle_id) == nil then
    return only_opts
  end
  return nil
end

--- Combine the bundled destructive-command deny rules with the user's own rules.
--- The defaults go first so they read as the baseline, though order does not decide the outcome:
--- can_use_tool checks every deny rule before any allow rule.
--- @param perms table config.permissions
--- @return PermissionRule[]
function M._resolve_permission_rules(perms)
  local user_rules = perms.rules or {}

  if perms.default_deny_rules == false then
    return user_rules
  end

  local destructive = require("vibing.core.constants.destructive_commands")
  local rules = vim.list_slice(destructive.DEFAULT_DENY_RULES)
  vim.list_extend(rules, user_rules)
  return rules
end

--- Build permission config from frontmatter opts (priority) or global config
--- @param handle_id string|nil
--- @return PermissionConfig
local function build_permission_config(handle_id)
  local config = Config.get()
  local perms = config.permissions or {}
  local o = get_active_opts(handle_id) or {}

  return {
    allowed_tools = o.permissions_allow or perms.allow or {},
    denied_tools = o.permissions_deny or perms.deny or {},
    asked_tools = o.permissions_ask or perms.ask or {},
    session_allowed_tools = session_state.allowed,
    session_denied_tools = session_state.denied,
    permission_rules = M._resolve_permission_rules(perms),
    permission_mode = o.permission_mode or perms.mode or "default",
    mcp_enabled = config.mcp and config.mcp.enabled or false,
  }
end

--- Get the communication directory for a given RPC port
--- @return string
local function get_comm_dir()
  return require("vibing.infrastructure.rpc.comm_dir").path()
end

--- Write response file for hook script
---
--- The file is a private protocol between this handler and `bin/hooks/pre-tool-use.sh`, so it
--- carries three decisions where the CLI's own hook schema has two:
---
---   "allow"  — an explicit grant. The hook prints this JSON verbatim on stdout, which makes the
---              CLI skip its own permission gate. Anything less is not a grant: a hook that just
---              exits 0 reads as "no opinion", and in headless `-p` mode the gate it falls
---              through to has no way to prompt, so the tool is refused (#564).
---   "deny"   — the hook exits 2 with the reason on stderr.
---   "defer"  — vibing.nvim permits the call but leaves the CLI's own gate (and with it the
---              user's own settings.json rules) in charge. The hook exits 0 silently.
---
--- @param request_id string
--- @param decision "allow"|"deny"|"defer"
--- @param reason? string Surfaced to the model as the tool_result when the underlying process
---   was NOT successfully cancelled (e.g. cancel_and_deny's fallback path). When cancellation
---   does succeed, the process is killed before this response can ever reach the model, so the
---   reason is moot in that case — it only matters for the failure path.
local function write_hook_response(request_id, decision, reason)
  local comm_dir = get_comm_dir()
  local res_file = comm_dir .. "/" .. request_id .. ".res"
  local tmp_file = res_file .. ".tmp"

  local output = { hookEventName = "PreToolUse", permissionDecision = decision }
  if reason then
    output.permissionDecisionReason = reason
  end
  local json = vim.json.encode({
    hookSpecificOutput = output,
  })

  local f, err = io.open(tmp_file, "w")
  if f then
    f:write(json)
    f:close()
    os.rename(tmp_file, res_file)
  else
    vim.schedule(function()
      vim.notify(
        string.format("[vibing:hook] Failed to write tmp file %s: %s", tmp_file, err or "unknown"),
        vim.log.levels.ERROR
      )
    end)
    local fallback_f, fallback_err = io.open(res_file, "w")
    if fallback_f then
      local deny_json = vim.json.encode({
        hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "deny" },
      })
      fallback_f:write(deny_json)
      fallback_f:close()
    else
      vim.schedule(function()
        vim.notify(
          string.format("[vibing:hook] Fallback write also failed %s: %s", res_file, fallback_err or "unknown"),
          vim.log.levels.ERROR
        )
      end)
    end
  end
end

--- Take both diff mechanisms' baselines, just before the tool runs.
---
--- This is the only point in a turn where "nothing has been changed yet" is guaranteed, so both
--- paths are seeded here:
---   - git snapshot (the main path) freezes the whole working tree as one tree object, which is
---     what catches a Bash-driven change. It only does work on the first tool that could write.
---   - request_diff (the fallback) backs up the pre-edit content of the file a tool named.
---
--- **Two pcalls, not one.** Sharing one would let the fallback take the main path down with it:
--- `request_diff.capture` creates its backup directory through `Fs.ensure_dir`, which re-raises
--- everything that is not the concurrent-creation race (a read-only filesystem, a permission
--- denial, a file where the directory should be). A throw there would skip `ensure_baseline`
--- entirely, and a turn whose only writing tool hit it would end with neither baseline and no
--- diff at all — the silent omission this whole mechanism exists to remove.
---
--- Neither failure may break the permission decision, which is why both are guarded at all.
--- @param effective_handle string|nil
--- @param cwd string|nil
--- @param tool_name string
--- @param tool_input table
function M._capture_baselines(effective_handle, cwd, tool_name, tool_input)
  pcall(function()
    -- 経路の選択は _handle_response が行う。ここは無条件にベースラインを取っておき、
    -- 使われなければ clear() で捨てられるだけ
    require("vibing.core.utils.git_snapshot").ensure_baseline(effective_handle, cwd, tool_name)
  end)
  pcall(function()
    require("vibing.core.utils.request_diff").capture(effective_handle, tool_name, tool_input)
  end)
end

--- Handle check_tool_permission RPC request
--- @param params {request_id: string, handle_id: string?}
--- @return table RPC response
function M.check_tool_permission(params)
  if not params or not params.request_id then
    return { error = "Missing request_id" }
  end

  local request_id = params.request_id
  local handle_id = params.handle_id
  if handle_id == "" then
    handle_id = nil
  end

  local comm_dir = get_comm_dir()
  local req_file = comm_dir .. "/" .. request_id .. ".req"

  local f = io.open(req_file, "r")
  if not f then
    write_hook_response(request_id, "defer")
    return { status = "allowed", reason = "request file not found" }
  end

  local content = f:read("*a")
  f:close()

  local ok, hook_input = pcall(vim.json.decode, content)
  if not ok or not hook_input then
    write_hook_response(request_id, "defer")
    return { status = "allowed", reason = "invalid request JSON" }
  end

  local active_opts = get_active_opts(handle_id)

  -- Backends name their tools differently (codex calls an edit "apply_patch"). The adapter
  -- supplies its own translation table as a generic `_tool_vocabulary`, so this handler stays
  -- ignorant of which backend it is serving -- adding a fourth needs no change here (#516).
  local vocabulary = active_opts and active_opts._tool_vocabulary

  -- Backends also disagree on the payload's own key names, not just the tool names inside it
  -- (grok sends `toolName`/`toolInput`). Normalize before reading, or the two calls below are
  -- handed nothing to translate.
  if vocabulary and vocabulary.normalize_payload then
    hook_input = vocabulary.normalize_payload(hook_input)
  end

  local tool_name = hook_input.tool_name or ""
  local tool_input = hook_input.tool_input or {}

  if vocabulary and vocabulary.to_canonical then
    tool_name = vocabulary.to_canonical(tool_name) or tool_name
  end
  -- Same reasoning for the input: granular `paths` rules read `file_path`, and a backend that
  -- names it `path`/`target_file` would slip past every one of them.
  if vocabulary and vocabulary.normalize_input then
    tool_input = vocabulary.normalize_input(tool_input)
  end

  -- Kill process first, call UI callback, then write deny response. Used by both
  -- AskUserQuestion and "ask" permission paths. The deny response only reaches the model when
  -- cancellation fails to find a stream (see fallback_reason below) — when the process is
  -- successfully killed, it dies before it could ever process that response.
  local function cancel_and_deny(on_stream_fn, fallback_reason)
    vim.schedule(function()
      local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
      local stream = registry.get(handle_id)
      local reason = nil
      if stream then
        if stream.adapter and stream.handle_id then
          stream.adapter:cancel(stream.handle_id)
        end
        on_stream_fn(stream)
      else
        vim.notify("[vibing] cancel_and_deny: no active stream found", vim.log.levels.WARN)
        reason = fallback_reason
      end
      write_hook_response(request_id, "deny", reason)
    end)
  end

  local perm_config = build_permission_config(handle_id)

  -- Native AskUserQuestion is unavailable in headless `claude -p` mode and is fully opaque to us
  -- (the SDK executes it internally), so the only way to handle it is to intercept + deny it here
  -- and render the choice UI ourselves. This branch is a harmless fallback kept in case the
  -- native tool is ever offered. vibing.nvim's own mcp__vibing-nvim__nvim_ask_user_question tool
  -- is the primary path and does NOT go through this hook: since we fully control its execution,
  -- its handler calls M.ask_user_question() (below) directly instead of being denied here.
  local is_ask_user_question_tool = tool_name == "AskUserQuestion"

  if is_ask_user_question_tool then
    cancel_and_deny(function(stream)
      if stream.on_insert_choices and tool_input.questions then
        stream.on_insert_choices(tool_input.questions)
      end
    end, "vibing.nvim could not find the chat buffer to show this question in (internal error). Ask the question as plain text instead of retrying this tool.")
    return { status = "denied", reason = "AskUserQuestion intercepted" }
  end

  local result = can_use_tool_mod.can_use_tool(tool_name, tool_input, perm_config)

  if result.behavior == "allow" then
    -- ツールが実行される前（=レスポンスを書いてフックのブロックを解く前）にベースラインを取る。
    -- 詳細と、pcallを2つに分けている理由は M._capture_baselines を参照
    local effective_handle = handle_id
    if not effective_handle then
      local ok_registry, registry =
        pcall(require, "vibing.infrastructure.adapter.modules.active_stream_registry")
      if ok_registry then
        local stream = registry.get(nil)
        effective_handle = stream and stream.handle_id
      end
    end
    M._capture_baselines(effective_handle, active_opts and active_opts.cwd or nil, tool_name, tool_input)
    -- Only vibing-nvim's own MCP tools are granted outright; everything else defers to the CLI's
    -- gate, which is still where the user's own settings.json rules are enforced. The distinction
    -- is not cosmetic: --allowedTools needs a literal prefix, and the plugin's is
    -- mcp__plugin_<marketplace>_vibing-nvim__ — a name decided at install time that this process
    -- cannot know. is_vibing_nvim_mcp_tool matches on the suffix instead, so granting here is the
    -- only form of the answer that survives the marketplace being renamed (#564).
    local decision = can_use_tool_mod.is_vibing_nvim_mcp_tool(tool_name) and "allow" or "defer"
    write_hook_response(request_id, decision)
    return { status = "allowed" }
  elseif result.behavior == "deny" then
    -- The reason has to go into the response, not just the return value: the hook script reads
    -- `permissionDecisionReason` and echoes it on stderr, which is the only way a deny rule's
    -- `message` ever reaches the model. Without it every denial reads as a bare "denied by hook".
    write_hook_response(request_id, "deny", result.message)
    return { status = "denied", reason = result.message }
  else
    -- "ask" → kill process first, show approval UI, then write deny
    -- User's approval choice updates session state; Claude retries on next message
    cancel_and_deny(function(stream)
      if stream.on_approval_required then
        stream.on_approval_required(tool_name, tool_input, APPROVAL_OPTIONS, request_id)
      end
    end, "vibing.nvim could not find the chat buffer to show the approval prompt in (internal error). Do not retry this tool immediately.")
    return { status = "pending" }
  end
end

--- Handle `ask_user_question` RPC request from the vibing-nvim MCP server's
--- `nvim_ask_user_question` tool handler. Unlike native AskUserQuestion (intercepted via
--- PreToolUse hook above, since the SDK executes it as a black box), this is vibing.nvim's own
--- MCP tool: its handler calls this directly instead of returning a real tool_result, so there is
--- no hook/deny plumbing here — just cancel the in-flight turn and show the same choice-list UI.
--- The killed turn means this RPC's return value is never seen by the model; the user's next
--- chat message (a fresh `--resume`d turn) delivers their answer instead.
--- @param params {chat_bufnr: number?, questions: table[]}
--- @return table RPC response
function M.ask_user_question(params)
  if not params or not params.questions then
    return { status = "error", reason = "Missing questions" }
  end

  local chat_bufnr = tonumber(params.chat_bufnr)

  local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
  local stream = registry.get_by_chat_bufnr(chat_bufnr)
  if not stream then
    return {
      status = "error",
      reason = "vibing.nvim could not find the chat buffer to show this question in (internal error).",
    }
  end

  if stream.adapter and stream.handle_id then
    local cancel_ok, cancel_err = pcall(function()
      stream.adapter:cancel(stream.handle_id)
    end)
    if not cancel_ok then
      vim.notify("[vibing] Failed to cancel stream for ask_user_question: " .. tostring(cancel_err), vim.log.levels.WARN)
    end
  end
  if stream.on_insert_choices then
    stream.on_insert_choices(params.questions)
  end

  return { status = "ok" }
end

--- Add tool to session allow list
function M.add_session_allow(tool_pattern, once)
  can_use_tool_mod.add_session_allow(session_state.allowed, tool_pattern, once)
end

--- Add tool to session deny list
function M.add_session_deny(tool_pattern, once)
  can_use_tool_mod.add_session_deny(session_state.denied, tool_pattern, once)
end

--- Reset session state
function M.reset_session()
  session_state.allowed = {}
  session_state.denied = {}
end

--- Get current session state
function M.get_session_state()
  return vim.deepcopy(session_state)
end

return M
