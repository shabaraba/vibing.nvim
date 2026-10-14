--- The one way a decision is handed back to `bin/hooks/pre-tool-use.sh`.
---
--- The hook writes a `<request_id>.req`, pokes this Neovim over RPC, and then **polls for
--- `<request_id>.res`**. The RPC reply is not the decision; this file is. Which is what lets an
--- approval be answered without killing the CLI (#778): withholding the `.res` blocks the hook,
--- and the hook is inside the CLI, so the turn simply waits.
---
--- It lives on its own because there are now two writers. `rpc/handlers/permission.lua` answers
--- synchronously for everything that needs no human, and `rpc/pending_approvals.lua` answers later
--- for the ones that do. A second copy of the `.tmp` + rename dance, or of the three-decision
--- vocabulary, is how the two would come to disagree about what "no opinion" looks like.
--- @module vibing.infrastructure.rpc.hook_response

local M = {}

--- Where a response for one request goes.
--- @param request_id string
--- @return string
function M.path(request_id)
  return require("vibing.infrastructure.rpc.comm_dir").path() .. "/" .. request_id .. ".res"
end

--- Write the response file the hook script is polling for.
---
--- The file is a private protocol between vibing.nvim and `bin/hooks/pre-tool-use.sh`, so it
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
--- @param reason? string Surfaced to the model as the tool_result when the underlying process was
---   NOT successfully cancelled. When cancellation does succeed, the process is killed before this
---   response can ever reach the model, so the reason is moot in that case.
function M.write(request_id, decision, reason)
  local res_file = M.path(request_id)
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
    return
  end

  vim.schedule(function()
    vim.notify(
      string.format("[vibing:hook] Failed to write tmp file %s: %s", tmp_file, err or "unknown"),
      vim.log.levels.ERROR
    )
  end)

  -- The fallback is a deny and not a defer, deliberately: we could not write what we decided, and
  -- the hook is blocked until something lands here. Denying is the answer that cannot be wrong in
  -- a way that matters.
  local fallback_f, fallback_err = io.open(res_file, "w")
  if fallback_f then
    local deny_json = vim.json.encode({
      hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "deny" },
    })
    fallback_f:write(deny_json)
    fallback_f:close()
    return
  end

  vim.schedule(function()
    vim.notify(
      string.format("[vibing:hook] Fallback write also failed %s: %s", res_file, fallback_err or "unknown"),
      vim.log.levels.ERROR
    )
  end)
end

return M
