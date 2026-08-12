--- Debug adapter (nvim-dap) access for the agent.
---
--- nvim-dap is an optional dependency: every entry point reports it as missing rather than
--- erroring, so a user without it sees an explanation instead of a stack trace.
---
--- DAP requests are callback-based while RPC handlers return a value, so each request is awaited
--- with vim.wait. That is safe here because the RPC server already dispatches handlers inside
--- vim.schedule -- we are on the main loop, and vim.wait keeps processing events, which is what
--- lets the debug adapter's reply arrive at all.
local M = {}

local REQUEST_TIMEOUT_MS = 5000

---@return table? dap
---@return string? reason
local function get_dap()
  local ok, dap = pcall(require, "dap")
  if not ok then
    return nil, "nvim-dap is not installed"
  end
  return dap, nil
end

---@return table? session
---@return string? reason
local function get_session()
  local dap, reason = get_dap()
  if not dap then
    return nil, reason
  end
  local session = dap.session()
  if not session then
    return nil, "no debug session is running"
  end
  return session, nil
end

--- dap_get_state hands the reason back as data; every other entry point raises it, so the MCP
--- layer turns it into a tool error the agent can read. Level 2 puts the calling handler's line
--- in the message rather than this helper's.
---@return table dap
local function require_dap()
  local dap, reason = get_dap()
  if not dap then
    error(reason, 2)
  end
  return dap
end

---@return table session
local function require_session()
  local session, reason = get_session()
  if not session then
    error(reason, 2)
  end
  return session
end

--- Await one DAP request.
--- `budget_ms` exists because vim.wait blocks the editor: a handler that issues several requests
--- must spend one shared budget across them, not a fresh 5s each, or a slow adapter freezes
--- Neovim for as long as it has scopes to ask about.
---@param session table
---@param command string
---@param arguments table
---@param budget_ms number? defaults to the per-request timeout
---@return table? body
---@return string? err
local function request(session, command, arguments, budget_ms)
  budget_ms = math.max(budget_ms or REQUEST_TIMEOUT_MS, 0)
  local done, body, err = false, nil, nil

  session:request(command, arguments, function(request_err, response)
    err = request_err and (request_err.message or vim.inspect(request_err))
    body = response
    done = true
  end)

  if not vim.wait(budget_ms, function()
    return done
  end, 20) then
    return nil, string.format("%s timed out after %dms", command, budget_ms)
  end

  return body, err
end

--- Counts down one wall-clock budget across several requests.
---@param total_ms number
---@return fun(): number remaining
local function deadline(total_ms)
  local started = vim.uv.now()
  return function()
    return math.max(total_ms - (vim.uv.now() - started), 0)
  end
end

--- The part of a stack frame the agent needs to name a location. `source.name` is the fallback
--- for frames the adapter has no file for (a REPL frame, generated code).
---@param frame table
---@return table
local function to_frame(frame)
  return {
    id = frame.id,
    name = frame.name,
    line = frame.line,
    column = frame.column,
    source = frame.source and (frame.source.path or frame.source.name),
  }
end

--- Top level of one scope. A scope that has no children, or whose read fails, is still reported
--- with an empty variable list: its name alone tells the agent the scope exists.
---@param session table
---@param scope table
---@param remaining fun(): number wall-clock left for the whole dap_get_variables call
---@return table[]
local function read_scope(session, scope, remaining)
  if not scope.variablesReference or scope.variablesReference <= 0 then
    return {}
  end

  local body, err = request(session, "variables", { variablesReference = scope.variablesReference }, remaining())
  if err then
    return {}
  end

  local variables = {}
  for _, variable in ipairs(body and body.variables or {}) do
    table.insert(variables, {
      name = variable.name,
      value = variable.value,
      type = variable.type,
    })
  end
  return variables
end

--- What the debugger is doing right now.
--- Answers "is there anything to inspect" without the agent having to guess from a failed call.
---@return table { running: boolean, reason: string?, adapter: string?, config_name: string?,
---   stopped_thread_id: number?, current_frame: table? }
function M.dap_get_state()
  local session, reason = get_session()
  if not session then
    return { running = false, reason = reason }
  end

  return {
    running = true,
    adapter = session.config and session.config.type,
    config_name = session.config and session.config.name,
    stopped_thread_id = session.stopped_thread_id,
    current_frame = session.current_frame and to_frame(session.current_frame),
  }
end

---@param params table? { thread_id: number? }
---@return table { frames: table[] }
function M.dap_get_stack_trace(params)
  local session = require_session()

  local thread_id = (params and params.thread_id) or session.stopped_thread_id
  if not thread_id then
    error("no stopped thread — the program is still running")
  end

  local body, err = request(session, "stackTrace", { threadId = thread_id })
  if err then
    error(err)
  end

  local frames = {}
  for _, frame in ipairs(body and body.stackFrames or {}) do
    table.insert(frames, to_frame(frame))
  end

  return { frames = frames }
end

--- Variables visible in one stack frame, grouped by scope.
--- Only the top level of each scope is expanded: a deep object graph would flood the chat, and the
--- agent can follow up with dap_evaluate on whatever it actually wants.
---@param params table? { frame_id: number? }
---@return table { scopes: { name: string, variables: { name: string, value: string, type: string? }[] }[] }
function M.dap_get_variables(params)
  local session = require_session()

  local frame_id = (params and params.frame_id) or (session.current_frame and session.current_frame.id)
  if not frame_id then
    error("no current frame — the program is not stopped")
  end

  -- One budget for the scopes request and every variables request under it. A frame can have
  -- several scopes, and per-request timeouts would multiply into tens of seconds of frozen editor.
  local remaining = deadline(REQUEST_TIMEOUT_MS)

  local body, err = request(session, "scopes", { frameId = frame_id }, remaining())
  if err then
    error(err)
  end

  local scopes = {}
  for _, scope in ipairs(body and body.scopes or {}) do
    table.insert(scopes, { name = scope.name, variables = read_scope(session, scope, remaining) })
  end

  return { scopes = scopes }
end

---@param params table { file: string, line: number, condition: string? }
---@return table { success: boolean, file: string, line: number }
function M.dap_set_breakpoint(params)
  local dap = require_dap()

  local file = params and params.file
  local line = params and params.line
  if type(file) ~= "string" or file == "" then
    error("file is required")
  end
  if type(line) ~= "number" or line < 1 or line ~= math.floor(line) then
    error("line must be a positive integer")
  end

  local path = vim.fn.fnamemodify(file, ":p")
  if vim.fn.filereadable(path) == 0 then
    error("file does not exist: " .. file)
  end

  -- The buffer has to exist for nvim-dap to attach the breakpoint to it, but it does not have to
  -- be displayed — setting a breakpoint should not yank the user's window somewhere else.
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)

  local breakpoints = require("dap.breakpoints")
  breakpoints.set({ condition = params.condition }, bufnr, line)

  -- A live session only learns about the new breakpoint when it is pushed to it.
  local session = dap.session()
  if session then
    breakpoints.set_breakpoints(session, bufnr)
  end

  return { success = true, file = path, line = line }
end

---@param params table { expression: string, frame_id: number? }
---@return table { result: string, type: string? }
function M.dap_evaluate(params)
  local session = require_session()

  local expression = params and params.expression
  if type(expression) ~= "string" or expression == "" then
    error("expression is required")
  end

  local body, err = request(session, "evaluate", {
    expression = expression,
    frameId = params.frame_id or (session.current_frame and session.current_frame.id),
    context = "repl",
  })
  if err then
    error(err)
  end

  return { result = body and body.result or "", type = body and body.type }
end

return M
