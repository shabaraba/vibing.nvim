--- CLI event processor for `claude -p --output-format stream-json` output
--- Processes JSON Lines from the Claude CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.cli_event_processor

local M = {}

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")

--- Extract brief summary from tool input for display
--- @param tool_name string
--- @param tool_input table
--- @return string
local function extract_input_summary(tool_name, tool_input)
  if tool_name == "Task" or tool_name == "Agent" then
    if tool_input.subagent_type and tool_input.subagent_type ~= "" then
      return tool_input.subagent_type
    end
    if tool_input.prompt and tool_input.prompt ~= "" then
      local p = vim.trim(tool_input.prompt)
      return #p > 30 and p:sub(1, 30) .. "..." or p
    end
    return "default"
  end

  return tool_input.command
    or tool_input.file_path
    or tool_input.pattern
    or tool_input.query
    or tool_input.url
    or ""
end

--- Format and emit a tool_result block as a chunk
--- @param block table tool_result content block
--- @param tool_map table tool_use_id → {name, input} map
--- @param context table event processing context
local function emit_tool_result(block, tool_map, context)
  local tool_info = tool_map[block.tool_use_id]
  if not tool_info then
    return
  end

  local tool_name = tool_info.name
  local tool_input = tool_info.input or {}
  local input_summary = extract_input_summary(tool_name, tool_input)

  local marker = ToolDisplay.resolve_marker(tool_name, ToolDisplay.get_cached_markers(context))
  local header = string.format("\n%s %s(%s)\n", marker, tool_name, input_summary)

  local result_text = ""
  if type(block.content) == "string" then
    result_text = block.content
  elseif type(block.content) == "table" then
    local parts = {}
    for _, c in ipairs(block.content) do
      if c.text then
        table.insert(parts, c.text)
      end
    end
    result_text = table.concat(parts, "")
  end

  if not context._cached_display_mode then
    context._cached_display_mode = ToolDisplay.get_display_mode()
  end
  local result_display = ToolDisplay.format_result_text(result_text, context._cached_display_mode)
  local text = header .. result_display

  if context.onChunk then
    table.insert(context.output, text)
    vim.schedule(function()
      context.onChunk(text)
    end)
  end

  tool_map[block.tool_use_id] = nil
end

--- Store session_id if present
--- @param msg table
--- @param context table
local function store_session(msg, context)
  if msg.session_id and context.sessionManager and context.handleId then
    SessionManagerModule.store(context.sessionManager, context.handleId, msg.session_id)
  end
end

--- Handle "system" event (init, hook events)
local function handle_system_event(msg, context)
  store_session(msg, context)
  -- Cancel timeout on first system event (proves CLI is alive)
  if context.onFirstResponse then
    context.onFirstResponse()
  end
end

--- Handle "stream_event" (partial streaming)
local function handle_stream_event(msg, context)
  local event = msg.event
  if not event then
    return
  end

  if event.type == "content_block_start" and event.content_block then
    local block = event.content_block
    if block.type == "tool_use" and block.name then
      context._tool_use_map = context._tool_use_map or {}
      context._tool_use_map[block.id] = {
        name = block.name,
        input = block.input or {},
        input_json = "",
      }
      context._current_tool_id = block.id
    end
  end

  if event.type == "content_block_delta" and event.delta then
    local delta = event.delta

    if delta.type == "text_delta" and delta.text and context.onChunk then
      table.insert(context.output, delta.text)
      vim.schedule(function()
        context.onChunk(delta.text)
      end)
    end

    if delta.type == "input_json_delta" and delta.partial_json then
      local tool_map = context._tool_use_map or {}
      if context._current_tool_id and tool_map[context._current_tool_id] then
        local info = tool_map[context._current_tool_id]
        if info.input_json ~= nil then
          info.input_json = info.input_json .. delta.partial_json
        end
      end
    end
  end

  store_session(msg, context)
end

--- Handle "assistant" event (complete response message)
local function handle_assistant_event(msg, context)
  local message = msg.message
  if not message then
    return
  end

  store_session(msg, context)

  local tool_map = context._tool_use_map or {}
  local emitted = context._emitted_tool_ids or {}

  for _, block in ipairs(message.content or {}) do
    -- Update tool_use_map with complete input from assistant message
    if block.type == "tool_use" and block.id then
      if tool_map[block.id] then
        tool_map[block.id].input = block.input or tool_map[block.id].input
        tool_map[block.id].name = block.name or tool_map[block.id].name
      else
        tool_map[block.id] = {
          name = block.name,
          input = block.input or {},
        }
      end

      -- Emit the tool callbacks with complete input (deferred from content_block_start).
      -- on_tool_use carries only the two fields the chat display needs; on_tool_use_full carries
      -- the input untouched, so the eval harness can assert on arguments like rpc_port or a full
      -- Bash command without widening the callback every chat depends on.
      local opts = context.opts or {}
      if not emitted[block.id] and (opts.on_tool_use or opts.on_tool_use_full) then
        emitted[block.id] = true
        local name = tool_map[block.id].name
        local input = tool_map[block.id].input or {}
        vim.schedule(function()
          if opts.on_tool_use then
            opts.on_tool_use(name, input.file_path, input.command)
          end
          if opts.on_tool_use_full then
            opts.on_tool_use_full(name, input)
          end
        end)
      end
    end

    if block.type == "tool_result" and block.tool_use_id then
      emit_tool_result(block, tool_map, context)
    end
  end

  context._tool_use_map = tool_map
  context._emitted_tool_ids = emitted
end

--- Handle "user" event (tool results in multi-turn)
local function handle_user_event(msg, context)
  local message = msg.message
  if not message then
    return
  end

  store_session(msg, context)

  local tool_map = context._tool_use_map or {}

  for _, block in ipairs(message.content or {}) do
    if block.type == "tool_result" and block.tool_use_id then
      emit_tool_result(block, tool_map, context)
    end
  end

  context._tool_use_map = tool_map
end

--- Handle "result" event (completion)
local function handle_result_event(msg, context)
  store_session(msg, context)

  if msg.subtype == "error" or msg.is_error then
    table.insert(context.errorOutput, msg.result or "Unknown error")
  end
end

--- Handle "text" event (error/unknown-command responses that bypass streaming)
local function handle_text_event(msg, context)
  if msg.text and context.onChunk then
    table.insert(context.output, msg.text)
    vim.schedule(function()
      context.onChunk(msg.text)
    end)
  end
end

--- Handle "rate_limit_event" (usage limit status)
--- Emitted mid-stream both as a remaining-quota warning and when a request is actually turned
--- away. Events are merged rather than replaced, because the two facts we need can arrive on
--- different events: a warning may carry `resetsAt` while the rejection that ends the turn omits
--- it. Merging newest-first keeps a fresher reset time while never losing a known one, and
--- rejection stays sticky so a trailing warning can't mask it.
---
--- Recorded on the context synchronously rather than dispatched through a callback: processLine
--- already runs inside vim.schedule, and deferring by another tick could land after the process
--- exit handler has already built the response, silently dropping the reset timestamp.
local function handle_rate_limit_event(msg, context)
  local RateLimit = require("vibing.core.utils.rate_limit")
  local info = RateLimit.from_event(msg)
  if not info then
    return
  end

  local previous = context.rateLimitInfo
  context.rateLimitInfo = previous and RateLimit.merge(info, previous) or info
end

--- Event handler dispatch table
local event_handlers = {
  system = function(msg, context)
    handle_system_event(msg, context)
    return true
  end,
  stream_event = function(msg, context)
    handle_stream_event(msg, context)
    return true
  end,
  assistant = function(msg, context)
    handle_assistant_event(msg, context)
    return true
  end,
  user = function(msg, context)
    handle_user_event(msg, context)
    return true
  end,
  result = function(msg, context)
    handle_result_event(msg, context)
    return true
  end,
  text = function(msg, context)
    handle_text_event(msg, context)
    return true
  end,
  rate_limit_event = function(msg, context)
    handle_rate_limit_event(msg, context)
    return true
  end,
}

--- Process a single JSON line from the CLI output
--- @param line string JSON string
--- @param context table Processing context
--- @return boolean success Whether the line was processed
function M.processLine(line, context)
  if line == "" or not context then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok or not msg or not msg.type then
    return false
  end

  local handler = event_handlers[msg.type]
  if handler then
    return handler(msg, context)
  end

  return true
end

return M
