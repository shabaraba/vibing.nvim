-- Explicit, local host probe, outside automated suites. Uses real Codex tokens.
if vim.env.VIBING_E2E ~= "1" or vim.env.VIBING_MACOS_RECORDING ~= "1" then
  return
end
local helper = require("vibing.testing.e2e_helper")
local root = vim.fn.getcwd()
local instance = helper.spawn_backend_instance("codex")
local function lua(code, args)
  return vim.fn.rpcrequest(instance.job_id, "nvim_exec_lua", code, args or {})
end
local ok, err = pcall(function()
  helper.setup_child(instance, {
    ai = { chat = { agent = "codex", model = "gpt-6-luna", effort = "low" },
      agents = { codex = { process = "duplex", extensions = {
        approval_policy = "on-request", profile_file = false, auto_approve = false,
      } } } },
    permissions = { mode = "default", allow = { "Bash" }, deny = {} },
    integrations = { plugins = { self = false, project_dir = false } },
  })
  helper.send_keys(instance, ":VibingChat<CR>")
  local ready, why = helper.wait_for_input_ready(instance, 10000)
  if not ready then error(why) end
  for index, kind in ipairs({ "chrome", "simulator" }) do
    local command = table.concat({ vim.fn.shellescape(vim.fn.exepath("node")),
      vim.fn.shellescape(root .. "/tests/fixtures/codex-native-approval/record-macos.mjs"),
      kind, "/private/tmp/issue861-recordings", "/private/tmp/issue861-recording" }, " ")
    local prompt = "Run exactly this one exec_command with sandbox_permissions=require_escalated, "
      .. "justification=macOS recording verification: " .. command
      .. ". Set yield_time_ms=30000. Wait for that process to finish with write_stdin using yield_time_ms=60000 if needed. "
      .. "Do not run any other command, install anything, or retry if it fails. Report the exit code."
    helper.send_keys(instance, "Gi" .. prompt .. "<Esc><CR>")
    local asked, reason = helper.wait_for_response(instance, "Tool: Codex command execution", 30000)
    if not asked then error(reason) end
    local pending = vim.wait(30000, function()
      return lua([[
        local chat = require("vibing.presentation.chat.view")._current_buffer
        return require("vibing.infrastructure.rpc.pending_native_approvals").has_for_chat(chat.buf)
      ]])
    end, 50)
    if not pending then error("No native request to answer for " .. kind) end
    lua([[
      local chat = require("vibing.presentation.chat.view")._current_buffer
      local pending = chat:get_pending_approvals()[1]
      local parser = require("vibing.presentation.chat.modules.approval_parser")
      local lines = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
      local header
      for i = #lines, 1, -1 do if lines[i]:match("^## User") then header = i; break end end
      for i, option in ipairs(pending.options) do
        if option.value == "accept" then
          vim.api.nvim_buf_set_lines(chat.buf, header, -1, false,
            { "", parser.option_line(i, option.label, pending.request_id) })
          chat:send_message()
          return
        end
      end
      error("accept was not offered")
    ]])
    local completed, failure = helper.wait_for_completed_turn(instance, index, 180000)
    print("CODEX_TURN " .. kind .. " " .. tostring(completed) .. " " .. tostring(failure))
    print(table.concat(lua([[return vim.api.nvim_buf_get_lines(require("vibing.presentation.chat.view")._current_buffer.buf, 0, -1, false)]]), "\n"))
    if not completed then error(failure) end
    local media = "/private/tmp/issue861-recordings/" .. (kind == "chrome" and "chrome.webm" or "simulator.mp4")
    print("MEDIA_EXISTS " .. kind .. " " .. tostring(vim.fn.filereadable(media) == 1))
  end
end)
helper.cleanup_instance(instance)
if not ok then error(err) end
