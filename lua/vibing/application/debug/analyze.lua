---@class Vibing.Application.Debug.Analyze
---デバッガが止まっている状態をチャットに投げて解析させる。
---
---状態そのものは送らない。送るのは「今の停止状態を調べてくれ」という依頼だけで、スタックも
---変数もエージェント自身がMCPツールで取りに行く。そのほうが必要な深さを本人が決められるし、
---巨大な変数ダンプをプロンプトに焼き込まずに済む。
local M = {}

local notify = require("vibing.core.utils.notify")

local ANALYZE_PROMPT = "The debugger is stopped. Use the nvim_dap_* tools to look at the stack "
  .. "trace and the variables in the current frame, then tell me what state the program is in and "
  .. "whether anything looks wrong. Name the specific variable and value if it does."

local HELP_PROMPT = "The debugger is stopped and I am stuck. Use the nvim_dap_* tools to inspect "
  .. "the current frame, then suggest what to check next — which expression to evaluate, or where "
  .. "to put the next breakpoint, and why."

---@return boolean stopped
---@return string? reason
local function is_stopped()
  local ok, dap = pcall(require, "dap")
  if not ok then
    return false, "nvim-dap is not installed"
  end
  local session = dap.session()
  if not session then
    return false, "no debug session is running"
  end
  if not session.stopped_thread_id and not session.current_frame then
    return false, "the program is running — stop at a breakpoint first"
  end
  return true, nil
end

---@param prompt string
---@return boolean sent
local function send(prompt)
  local stopped, reason = is_stopped()
  if not stopped then
    notify.warn(reason, "Debug")
    return false
  end

  local view = require("vibing.presentation.chat.view")
  local current = view.get_current()
  if not current then
    require("vibing.presentation.chat.controller").handle_open("")
    current = view.get_current()
  end
  if not current then
    notify.error("Could not open a chat to analyze in", "Debug")
    return false
  end

  -- 送信経路はnvim_chat_send_messageと同じProgrammaticSender。バッファ側のロックや
  -- カーソル復帰をここで書き直さない
  local sender = require("vibing.presentation.chat.modules.programmatic_sender")
  local ok, err = pcall(sender.send, current.buf, prompt)
  if not ok then
    notify.error("Could not send the analysis request: " .. tostring(err), "Debug")
    return false
  end

  return true
end

---:VibingDebugAnalyze
---@return boolean sent
function M.analyze()
  return send(ANALYZE_PROMPT)
end

---:VibingDebugHelp
---@return boolean sent
function M.help()
  return send(HELP_PROMPT)
end

---@param config table config.dap
---@return boolean armed
function M.setup(config)
  config = config or {}
  if not config.enabled then
    return false
  end

  local ok, dap = pcall(require, "dap")
  if not ok then
    -- 明示的にenabledにした人が黙って何も起きない状態にならないように言う
    notify.warn("dap.enabled is set but nvim-dap is not installed", "Debug")
    return false
  end

  -- 例外で止まったのか、ただのブレークポイントなのかで既定を変える。例外は起きた時点で
  -- 何かが壊れているが、ブレークポイントは意図して置いたものなので、止まるたびに無人で
  -- トークンを使われると邪魔になる
  dap.listeners.after.event_stopped["vibing"] = function(_, body)
    local wanted
    if body and body.reason == "exception" then
      wanted = config.auto_analyze_on_error
    else
      wanted = config.auto_analyze_on_breakpoint
    end
    if not wanted then
      return
    end

    vim.schedule(function()
      M.analyze()
    end)
  end

  return true
end

return M
