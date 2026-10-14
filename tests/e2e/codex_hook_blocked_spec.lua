-- Real hooks: deny remains final, ask is answered through the existing chat retry route.
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

describe("E2E: Codex duplex hook blocks", function()
  local instance
  after_each(function()
    helper.cleanup_instance(instance)
  end)

  local function setup(permissions, disconnect)
    instance = helper.spawn_backend_instance("codex")
    helper.setup_child(instance, {
      ai = {
        chat = { agent = "codex", model = "gpt-6-luna", effort = "low" },
        agents = {
          codex = {
            process = "duplex",
            extensions = {
              profile_file = false,
              approval_policy = "never",
            },
          },
        },
      },
      permissions = permissions,
      integrations = { plugins = { self = false, project_dir = false } },
    })
    helper.send_keys(instance, ":VibingChat<CR>")
    assert.is_true(helper.wait_for_buffer_name(instance, "%.md$", 5000))
    local ready, reason = helper.wait_for_input_ready(instance, 10000)
    assert.is_true(ready, reason)
    lua(
      instance,
      [[
      local disconnect = ...
      _G.hook_probe = { frames = {}, inputs = {} }
      local protocol = require("vibing.infrastructure.adapter.modules.codex_duplex_protocol")
      local permission = require("vibing.infrastructure.rpc.handlers.permission")
      local line, normalize = protocol.process_line, permission.normalize_hook_input
      protocol.process_line = function(record, text)
        local ok, msg = pcall(vim.json.decode, text)
        if ok and msg.method then
          table.insert(hook_probe.frames, msg)
          if disconnect and msg.method == "turn/started" then
            require("vibing.infrastructure.rpc.server").stop()
          end
        end
        return line(record, text)
      end
      permission.normalize_hook_input = function(input, vocabulary)
        local tool, args = normalize(input, vocabulary)
        table.insert(hook_probe.inputs, { tool = tool, input = args, raw = input })
        return tool, args
      end
    ]],
      { disconnect or false }
    )
  end

  local function send(marker)
    helper.send_keys(
      instance,
      'GiRun exactly one exec_command with cmd="printf hook > '
        .. marker
        .. '". Do not use any other tool or retry if refused. Then reply OK.<Esc><CR>'
    )
  end

  it("shows a denied call with its reason and offers no permission override", function()
    setup({ mode = "default", allow = { "Bash" }, deny = { "Bash" } })
    local marker = instance.repo_dir .. "/denied.txt"
    send(marker)
    local done, reason = helper.wait_for_completed_turn(instance, 1, TIMEOUTS.COMPLETE)
    assert.is_true(done, reason)
    local result = lua(
      instance,
      [[
      local chat = require("vibing.presentation.chat.view")._current_buffer
      return { vim.fn.filereadable(...), #chat:get_pending_approvals(),
        table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n") }
    ]],
      { marker }
    )
    assert.same({ 0, 0 }, { result[1], result[2] })
    assert.matches("PreToolUse hook blocked", result[3])
    assert.matches("Tool Bash is in the denied list", result[3])
    assert.is_truthy(result[3]:find("Bash(printf hook > " .. marker .. ")", 1, true))
  end)

  it("continues the same operation after a chat allow_once answer", function()
    setup({ mode = "default", allow = { "Bash" }, deny = {}, ask = { "Bash" } })
    local marker = instance.repo_dir .. "/approved.txt"
    send(marker)
    local asked, reason = helper.wait_for_response(instance, "Tool approval required", TIMEOUTS.APPROVAL)
    assert.is_true(asked, reason)
    assert.equals(0, lua(instance, [[return vim.fn.filereadable(...)]], { marker }))
    lua(
      instance,
      [[
      local chat = require("vibing.presentation.chat.view")._current_buffer
      local pending = chat:get_pending_approvals()[1]
      local lines = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
      local header
      for i = #lines, 1, -1 do
        if lines[i]:match("^## User") then header = i; break end
      end
      vim.api.nvim_buf_set_lines(chat.buf, header, -1, false, { "",
        require("vibing.presentation.chat.modules.approval_parser").option_line(1,
          pending.options[1].label, pending.request_id) })
      chat:send_message()
    ]]
    )
    local done, why = helper.wait_for_completed_turn(instance, 2, TIMEOUTS.COMPLETE)
    assert.is_true(done, why)
    local result = lua(
      instance,
      [[
      local chat = require("vibing.presentation.chat.view")._current_buffer
      return { vim.fn.filereadable(...), #chat:get_pending_approvals(),
        chat:get_frontmatter_list("permissions_allow"), chat:get_frontmatter_list("permissions_deny"),
        #hook_probe.inputs, hook_probe.inputs[1].input.command == hook_probe.inputs[2].input.command }
    ]],
      { marker }
    )
    assert.same({ 1, 0, { "Bash", "Skill" }, {}, 2, true }, result)
  end)

  it("reports an unreachable RPC server without offering an approval", function()
    setup({ mode = "default", allow = { "Bash" }, deny = {} }, true)
    local marker = instance.repo_dir .. "/unreachable.txt"
    send(marker)
    local done, reason = helper.wait_for_completed_turn(instance, 1, TIMEOUTS.COMPLETE)
    assert.is_true(done, reason)
    local result = lua(
      instance,
      [[
      local chat = require("vibing.presentation.chat.view")._current_buffer
      return { vim.fn.filereadable(...), #chat:get_pending_approvals(),
        table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n") }
    ]],
      { marker }
    )
    assert.same({ 0, 0 }, { result[1], result[2] })
    assert.matches("Failed to connect to vibing.nvim RPC server", result[3])
    assert.matches("Approval cannot repair", result[3])
  end)
end)
