-- Real app-server requests, answered through the same option-line path as <CR>.
local helper = require("vibing.testing.e2e_helper")
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  APPROVAL = 20000,
  COMPLETE = 30000,
}
local function lua(instance, source, args)
  return vim.fn.rpcrequest(instance.job_id, "nvim_exec_lua", source, args or {})
end

describe("E2E: Codex native approval decisions", function()
  local instance
  after_each(function()
    helper.cleanup_instance(instance)
  end)

  it("accepts, declines and cancels without removing the workspace sandbox", function()
    instance = helper.spawn_backend_instance("codex")
    helper.setup_child(instance, {
      ai = { chat = { agent = "codex", model = "gpt-6-luna", effort = "low" },
        agents = { codex = { process = "duplex", extensions = {
          approval_policy = "on-request", profile_file = false, auto_approve = false,
        } } } },
      permissions = { mode = "default", allow = { "Bash" }, deny = {} },
      integrations = { plugins = { self = false, project_dir = false } },
    })
    helper.send_keys(instance, ":VibingChat<CR>")
    assert.is_true(helper.wait_for_buffer_name(instance, "%.md$", 5000))
    local ready, reason = helper.wait_for_input_ready(instance, 10000)
    assert.is_true(ready, reason)

    -- Observe real protocol traffic; do not replace the decoder or the reply writer.
    lua(instance, [[
      _G.approval_probe = { replies = {}, requests = {}, statuses = {} }
      local protocol = require("vibing.infrastructure.adapter.modules.codex_duplex_protocol")
      local process = require("vibing.infrastructure.adapter.modules.duplex_process")
      local line, write = protocol.process_line, process.write_to
      protocol.process_line = function(record, text)
        local ok, msg = pcall(vim.json.decode, text)
        if ok and msg.method == "item/commandExecution/requestApproval" then
          table.insert(approval_probe.requests, msg)
        elseif ok and msg.method == "turn/completed" then
          table.insert(approval_probe.statuses, msg.params.turn.status)
        end
        return line(record, text)
      end
      process.write_to = function(job, msg)
        if msg.result and msg.result.decision then table.insert(approval_probe.replies, msg) end
        return write(job, msg)
      end
    ]])

    for index, action in ipairs({ "accept", "decline", "cancel" }) do
      local marker = instance.repo_dir .. "/" .. action .. ".txt"
      local prompt = string.format(
        "Run exactly one exec_command with cmd=\"printf native > %s\", "
          .. "sandbox_permissions=\"require_escalated\" and justification=\"native approval test\". "
          .. "Request escalation even though the path is inside the workspace. "
          .. "Do not use any other tool or retry if denied. Then reply OK.", marker)
      helper.send_keys(instance, "Gi" .. prompt .. "<Esc><CR>")
      local asked, why = helper.wait_for_response(instance, "Tool: Codex command execution", TIMEOUTS.APPROVAL)
      assert.is_true(asked, why)
      assert.is_true(vim.wait(TIMEOUTS.APPROVAL, function()
        return lua(instance, [[
          local chat = require("vibing.presentation.chat.view")._current_buffer
          return require("vibing.infrastructure.rpc.pending_native_approvals").has_for_chat(chat.buf)
        ]])
      end, 50), "a fresh request should be registered for this turn")
      local before = lua(instance, [[
        local chat = require("vibing.presentation.chat.view")._current_buffer
        local pending = require("vibing.infrastructure.rpc.pending_native_approvals").list_for_chat(chat.buf)
        return { #pending, #approval_probe.replies }
      ]])
      assert.same({ 1, index - 1 }, before, "request should still be blocked before answering")
      lua(instance, [[
        local action = ...
        local chat = require("vibing.presentation.chat.view")._current_buffer
        local pending = chat:get_pending_approvals()[1]
        local parser = require("vibing.presentation.chat.modules.approval_parser")
        local lines = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
        local header
        for i = #lines, 1, -1 do
          if lines[i]:match("^## User") then header = i; break end
        end
        for i, option in ipairs(pending.options) do
          if option.value == action then
            vim.api.nvim_buf_set_lines(chat.buf, header, -1, false,
              { "", parser.option_line(i, option.label, pending.request_id) })
            chat:send_message()
            return
          end
        end
        error("decision not offered: " .. action)
      ]], { action })
      if action ~= "cancel" then
        local done, err = helper.wait_for_completed_turn(instance, index, TIMEOUTS.COMPLETE)
        assert.is_true(done, err)
      else
        assert.is_true(vim.wait(TIMEOUTS.COMPLETE, function()
          return lua(instance, [[return #approval_probe.statuses == 3]])
        end, 50), "cancel should interrupt the real turn")
      end
      local result = lua(instance, [[
        local index, marker = ...
        local chat = require("vibing.presentation.chat.view")._current_buffer
        local record = require("vibing.infrastructure.adapter.modules.duplex_pool").get(chat.buf)
        local request, reply = approval_probe.requests[index], approval_probe.replies[index]
        local argv = vim.split(record.argv_key, string.char(30), { plain = true })
        return {
          #approval_probe.requests, #approval_probe.replies,
          reply.id == request.id, reply.result.decision, approval_probe.statuses[index],
          vim.fn.filereadable(marker),
          require("vibing.infrastructure.rpc.pending_native_approvals").count(),
          chat:get_session_allow(), chat:get_session_deny(),
          vim.tbl_contains(argv, 'sandbox_mode="workspace-write"'),
          vim.tbl_contains(argv, 'approval_policy="on-request"'),
        }
      ]], { index, marker })
      assert.same({ index, index, true, action, action == "cancel" and "interrupted" or "completed",
        action == "accept" and 1 or 0, 0, {}, {}, true, true }, result)
    end
  end)
end)
