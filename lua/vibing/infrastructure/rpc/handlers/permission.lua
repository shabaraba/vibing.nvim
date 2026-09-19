--- RPC handler for tool permission checks from pre-tool-use hook
--- @module vibing.infrastructure.rpc.handlers.permission

local can_use_tool_mod = require("vibing.infrastructure.permissions.can_use_tool")
local Config = require("vibing.config")
local HookScope = require("vibing.infrastructure.rpc.hook_scope")

local M = {}

--- Active chat frontmatter overrides, keyed by **turn id** (set by stream start). A single shared
--- slot would let one chat buffer's opts silently apply to another's permission checks whenever
--- two chats stream concurrently (see turn_registry.lua for the same class of bug).
---
--- The session-level allow/deny lists an approval answer produces live in here too, for exactly
--- that reason (#667). They used to sit in a module-level table instead, so a `deny_once` answered
--- in a worker chat was consumed by whichever chat called that tool next, and an
--- `allow_for_session` granted in a throwaway worker silently applied to every chat in the editor
--- — bypassing each one's own `permissions_ask`. The per-chat lists were already plumbed this far
--- as `permissions_session_allow` / `permissions_session_deny` (`send_message.lua`); only
--- `build_permission_config` was still reading the shared table.
---
--- **Per turn, not per process,** even though the values belong to the chat: every one of them is
--- re-read from frontmatter on each send, and the lists grow by one entry each time an approval is
--- answered. Keyed by the process, a resident process (#774) would run turn N+1 under turn N's
--- `permission_mode` and ignore the very allow entry the user's approval had just produced — #667
--- re-opened from the other end.
--- @type table<string, table>
local active_opts_by_turn = {}

--- Kill the CLI process serving an open turn.
---
--- Killing is done to a process, so it is named by one -- which is why the turn holds a reference to
--- its process rather than a copy of the adapter. The turn stops as a consequence, which is the
--- whole mechanism today and the thing #774 replaces with an interrupt. Both places that stop a turn
--- to show UI in its place go through here, so there is one definition of what cancelling means.
--- @param turn Vibing.TurnEntry
--- @return boolean ok false when cancelling raised
local function cancel_turn(turn)
  local process = turn.process
  if not (process and process.adapter and process.process_id) then
    return true
  end
  local ok, err = pcall(function()
    process.adapter:cancel(process.process_id)
  end)
  if not ok then
    vim.notify("[vibing] Failed to cancel the turn's process: " .. tostring(err), vim.log.levels.WARN)
  end
  return ok
end

local APPROVAL_OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

--- Set active permission opts from chat frontmatter
--- @param turn_id string
--- @param opts table
function M.set_active_opts(turn_id, opts)
  active_opts_by_turn[turn_id] = opts
end

--- Clear active opts
--- @param turn_id string
function M.clear_active_opts(turn_id)
  active_opts_by_turn[turn_id] = nil
end

--- Resolve the frontmatter opts for one turn.
---
--- No fallback of its own: `rpc/hook_scope.lua` has already decided which turn this is, including
--- whether guessing was allowed. This used to hold a second, *different* guess — it fell back to the
--- sole entry even for an id that was present but unmatched, so a hook arriving from a turn that had
--- already unregistered had another chat's decisions applied to it.
--- @param turn_id string|nil
--- @return table|nil
local function get_active_opts(turn_id)
  return turn_id and active_opts_by_turn[turn_id] or nil
end

--- Test seam. "A turn's opts are set when it starts and gone when it ends" has no other observable
--- effect, so a spec asserting it has nothing to read — and the one that tried asserted
--- `perm_handler.get_active_opts_for_test == nil`, a name that never existed, so it passed whatever
--- the code did. Under a resident process the invariant stops being incidental: turn N+1 inheriting
--- turn N's entry means it runs under the wrong `permission_mode`.
--- @param turn_id string|nil
--- @return table|nil
M._get_active_opts = get_active_opts

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
--- @param turn_id string|nil
--- @return PermissionConfig
local function build_permission_config(turn_id)
  local config = Config.get()
  local perms = config.permissions or {}
  local o = get_active_opts(turn_id) or {}

  return {
    allowed_tools = o.permissions_allow or perms.allow or {},
    denied_tools = o.permissions_deny or perms.deny or {},
    asked_tools = o.permissions_ask or perms.ask or {},
    -- 承認の答えはそのチャットのセッションに属する。`o` から読むことで、あるチャットで出した
    -- 判断が別のチャットの判定に混ざらない（#667）。`o` が引けないとき（hook_scope がターンを
    -- 特定できなかった＝プロセスが未登録、または無名のフックが複数ストリーム中に来た）は空に
    -- なるが、`for_session` の許可/拒否は frontmatter にも書かれていて `permissions_allow` /
    -- `permissions_deny` として上の行から入るので、ここで落ちるのはメモリ上にしか無い
    -- `:once` だけになる
    session_allowed_tools = o.permissions_session_allow or {},
    session_denied_tools = o.permissions_session_deny or {},
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
---
--- All three mechanisms are keyed by the **turn**, which is what `_handle_response` looks them up
--- by when it renders `### Modified Files`. A nil turn takes no baseline at all: that is the case
--- where the hook named a process nothing has registered, and a baseline filed under an unknown key
--- is never cleared, because `clear()` is only reached through a response.
--- @param turn_id string|nil
--- @param cwd string|nil
--- @param tool_name string
--- @param tool_input table
function M._capture_baselines(turn_id, cwd, tool_name, tool_input)
  if not turn_id then
    return
  end
  pcall(function()
    -- 経路の選択は _handle_response が行う。ここは無条件にベースラインを取っておき、
    -- 使われなければ clear() で捨てられるだけ
    require("vibing.core.utils.git_snapshot").ensure_baseline(turn_id, cwd, tool_name)
  end)
  pcall(function()
    require("vibing.core.utils.request_diff").capture(turn_id, tool_name, tool_input)
  end)
  pcall(function()
    -- ここも「ツールが走る前」であることが要る。worktreeを作るコマンドの前後を比べるので、
    -- 押さえるのは実行前の一覧でなければならない
    require("vibing.application.chat.worktree_binding").observe(
      turn_id,
      cwd,
      tool_name,
      tool_input
    )
  end)
end

--- Handle check_tool_permission RPC request
--- @param params {request_id: string, process_id: string?}
--- @return table RPC response
--- The canonical tool name and input for a hook payload, through a backend's vocabulary.
---
--- Three steps, in an order that matters because each feeds the next (`cli-integration.md` →
--- "Backend Seams"): the payload's own key names first (grok sends `toolName`/`toolInput`; read
--- straight through, the two steps below get nothing to work on), then the tool's name
--- (`apply_patch` → `Edit`), then where the path lives inside the input (granular `paths` rules
--- read `file_path`, and a backend that names it `path`/`target_file` would slip past every one
--- of them). A vocabulary may implement any subset; a backend that speaks the canonical
--- vocabulary passes none.
--- @param hook_input table the decoded hook payload
--- @param vocabulary table|nil
--- @return string tool_name canonical
--- @return table tool_input with `file_path` where the backend had a path under another key
function M.normalize_hook_input(hook_input, vocabulary)
  if vocabulary and vocabulary.normalize_payload then
    hook_input = vocabulary.normalize_payload(hook_input)
  end

  local tool_name = hook_input.tool_name or ""
  local tool_input = hook_input.tool_input or {}

  if vocabulary and vocabulary.to_canonical then
    tool_name = vocabulary.to_canonical(tool_name) or tool_name
  end
  if vocabulary and vocabulary.normalize_input then
    tool_input = vocabulary.normalize_input(tool_input)
  end
  return tool_name, tool_input
end

function M.check_tool_permission(params)
  if not params or not params.request_id then
    return { error = "Missing request_id" }
  end

  local request_id = params.request_id
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

  -- Resolved once for the whole synchronous decision, so the opts, the permission config and the
  -- baseline key cannot disagree about which turn this is. Deriving it separately at each of those
  -- three points is what let them drift onto two different policies (see rpc/hook_scope.lua).
  local scope = HookScope.of(params)
  local active_opts = get_active_opts(scope.turn_id)

  -- Backends name their tools differently (codex calls an edit "apply_patch"). The adapter
  -- supplies its own translation table as a generic `_tool_vocabulary`, so this handler stays
  -- ignorant of which backend it is serving -- adding a fourth needs no change here (#516).
  local tool_name, tool_input = M.normalize_hook_input(hook_input, active_opts and active_opts._tool_vocabulary)

  -- Kill process first, call UI callback, then write deny response. Used by both
  -- AskUserQuestion and "ask" permission paths. The deny response only reaches the model when
  -- cancellation fails to find a turn (see fallback_reason below) — when the process is
  -- successfully killed, it dies before it could ever process that response.
  local function cancel_and_deny(on_turn_fn, fallback_reason)
    vim.schedule(function()
      -- Re-resolved here rather than reused from `scope` above: the turn can finish between the
      -- synchronous decision and this callback, and firing the approval UI at a turn that has
      -- already closed would leave a prompt in the buffer with nothing left to answer it.
      -- Same policy, because it is the same function -- what differs is only when it is asked.
      local turn = HookScope.of(params).entry
      local reason = nil
      if turn then
        cancel_turn(turn)
        on_turn_fn(turn)
      else
        vim.notify("[vibing] cancel_and_deny: no open turn found", vim.log.levels.WARN)
        reason = fallback_reason
      end
      write_hook_response(request_id, "deny", reason)
    end)
  end

  local perm_config = build_permission_config(scope.turn_id)

  -- Native AskUserQuestion is unavailable in headless `claude -p` mode and is fully opaque to us
  -- (the SDK executes it internally), so the only way to handle it is to intercept + deny it here
  -- and render the choice UI ourselves. This branch is a harmless fallback kept in case the
  -- native tool is ever offered. vibing.nvim's own mcp__vibing-nvim__nvim_ask_user_question tool
  -- is the primary path and does NOT go through this hook: since we fully control its execution,
  -- its handler calls M.ask_user_question() (below) directly instead of being denied here.
  local is_ask_user_question_tool = tool_name == "AskUserQuestion"

  if is_ask_user_question_tool then
    cancel_and_deny(function(turn)
      if turn.on_insert_choices and tool_input.questions then
        turn.on_insert_choices(tool_input.questions)
      end
    end, "vibing.nvim could not find the chat buffer to show this question in (internal error). Ask the question as plain text instead of retrying this tool.")
    return { status = "denied", reason = "AskUserQuestion intercepted" }
  end

  local result = can_use_tool_mod.can_use_tool(tool_name, tool_input, perm_config)

  if result.behavior == "allow" then
    -- ツールが実行される前（=レスポンスを書いてフックのブロックを解く前）にベースラインを取る。
    -- 詳細と、pcallを2つに分けている理由は M._capture_baselines を参照
    M._capture_baselines(scope.turn_id, active_opts and active_opts.cwd or nil, tool_name, tool_input)
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
    cancel_and_deny(function(turn)
      if turn.on_approval_required then
        turn.on_approval_required(tool_name, tool_input, APPROVAL_OPTIONS, request_id)
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

  local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
  local turn = TurnRegistry.get_by_chat_bufnr(chat_bufnr)
  if not turn then
    return {
      status = "error",
      reason = "vibing.nvim could not find the chat buffer to show this question in (internal error).",
    }
  end

  cancel_turn(turn)
  if turn.on_insert_choices then
    turn.on_insert_choices(params.questions)
  end

  return { status = "ok" }
end

return M
