--- Renders canonical stream events into the chat: the one place that decides what a tool call
--- looks like, when `on_tool_use` fires, how subagent text is shown and where usage lands.
---
--- Before ADR 009 each backend's event processor did this itself, so codex drew
--- `FileChange(2 files)` where claude drew `Edit(path)` and copilot drew a header at tool start
--- where claude drew it with the result. None of that was a fact about the backend. A decoder
--- (`decoders/<backend>.lua`) now translates the CLI's own JSON into the `Vibing.CanonicalEvent`
--- shapes below and stops; this module does the rest, identically for every backend.
---
--- Tool names arrive in the backend's own vocabulary and are canonicalised here through
--- `context.vocabulary` (the same table the permission handler uses), so a tool is called the same
--- thing in the chat and in a permission rule.
--- @module vibing.infrastructure.adapter.modules.event_renderer

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")
local SubagentDisplay = require("vibing.infrastructure.adapter.modules.subagent_display")
local SubagentMarker = require("vibing.infrastructure.adapter.modules.subagent_marker")
local TokenUsage = require("vibing.core.utils.token_usage")

---@alias Vibing.CanonicalEvent
---| { kind: "session", session_id: string }                          # the CLI named its session
---| { kind: "first_response" }                                       # proof the CLI is alive (resume timeout)
---| { kind: "text", delta: string }                                  # assistant prose, streamed
---| { kind: "thinking", delta: string }                              # reasoning the CLI chose to expose
---| { kind: "tool_start", id: string, name: string, input: table }   # native name; canonicalised here
---| { kind: "tool_end", id: string, result: string?, is_error: boolean? }
---| { kind: "subagent_text", parent_id: string, text: string }       # text a subagent produced under tool `parent_id`
---| { kind: "usage", record: table, subagent: boolean? }             # one request's usage, accumulated
---| { kind: "usage", accumulator: table }                            # a whole-turn accumulator, replacing
---| { kind: "cli_info", version: string?, model: string?, tools: number?, mcp_servers: number?, compacted: boolean? }
---| { kind: "rate_limit", info: Vibing.RateLimitInfo }
---| { kind: "error", message: string, fatal: boolean? }              # fatal: the CLI declared the turn failed

local M = {}

--- @param text string
--- @param context table
local function emit(text, context)
  if not text or text == "" then
    return
  end
  table.insert(context.output, text)
  if context.onChunk then
    vim.schedule(function()
      context.onChunk(text)
    end)
  end
end

--- @param context table
--- @param name string
--- @return string
local function canonical_name(context, name)
  local vocabulary = context.vocabulary
  if vocabulary and vocabulary.to_canonical then
    return vocabulary.to_canonical(name) or name
  end
  return name
end

--- @param context table
--- @param input table
--- @return table
local function canonical_input(context, input)
  local vocabulary = context.vocabulary
  if vocabulary and vocabulary.normalize_input then
    return vocabulary.normalize_input(input) or input
  end
  return input
end

--- Brief summary of a tool's input for the `Name(summary)` header.
--- @param tool_name string canonical
--- @param tool_input table
--- @return string
local function input_summary(tool_name, tool_input)
  if SubagentMarker.is_subagent_tool(tool_name) then
    if tool_input.subagent_type and tool_input.subagent_type ~= "" then
      return tool_input.subagent_type
    end
    if tool_input.prompt and tool_input.prompt ~= "" then
      local p = vim.trim(tool_input.prompt)
      return #p > 30 and p:sub(1, 30) .. "..." or p
    end
    return "default"
  end

  if type(tool_input.file_paths) == "table" and #tool_input.file_paths > 0 then
    return table.concat(tool_input.file_paths, ", ")
  end

  return tool_input.command
    or tool_input.file_path
    or tool_input.notebook_path
    or tool_input.pattern
    or tool_input.query
    or tool_input.url
    or ""
end

--- Leave thinking mode, if in it. Called by everything that is not a thinking delta so the
--- `💭` block is closed before the next thing is drawn.
--- @param context table
--- @param separator string? emitted when leaving thinking mode
local function close_thinking(context, separator)
  if context._render_mode == "thinking" then
    context._render_mode = "text"
    if separator then
      emit(separator, context)
    end
  end
end

--- @param context table
--- @return table<string, {name: string, input: table}>
local function tools(context)
  context._tools = context._tools or {}
  return context._tools
end

local handlers = {}

-- Stored under the process, not the turn: a CLI session is something the process holds open, and
-- `send_message._handle_response` reads it back off `response._process_id` to learn what the next
-- turn should `--resume`.
handlers.session = function(event, context)
  if event.session_id and context.sessionManager and context.processId then
    SessionManagerModule.store(context.sessionManager, context.processId, event.session_id)
  end
end

handlers.first_response = function(_, context)
  if context.onFirstResponse then
    context.onFirstResponse()
  end
end

handlers.text = function(event, context)
  close_thinking(context, "\n\n")
  context._render_mode = "text"
  emit(event.delta, context)
end

handlers.thinking = function(event, context)
  if context._render_mode ~= "thinking" then
    context._render_mode = "thinking"
    emit("\n💭 ", context)
  end
  emit(event.delta, context)
end

handlers.tool_start = function(event, context)
  if not event.id or not event.name then
    return
  end
  local name = canonical_name(context, event.name)
  local input = canonical_input(context, event.input or {})
  tools(context)[event.id] = { name = name, input = input }

  -- Counted once per tool id, independent of whether a chat wired on_tool_use -- unlike
  -- `_emitted` below, which only exists to dedupe that callback and stays empty without it.
  context._subagent_started = context._subagent_started or {}
  if SubagentMarker.is_subagent_tool(name) and not context._subagent_started[event.id] then
    context._subagent_started[event.id] = true
    -- Required lazily: specs reload the registry module, and a reference taken at load time
    -- would keep counting into the instance they discarded.
    require("vibing.infrastructure.adapter.modules.turn_registry").increment_subagent_count(context.turnId)
  end

  -- on_tool_use carries only the two fields the chat display needs; on_tool_use_full carries the
  -- input untouched, so the eval harness can assert on arguments without widening the callback
  -- every chat depends on. A tool that touches several files reports each one.
  local opts = context.opts or {}
  context._emitted_tool_ids = context._emitted_tool_ids or {}
  if not context._emitted_tool_ids[event.id] and (opts.on_tool_use or opts.on_tool_use_full) then
    context._emitted_tool_ids[event.id] = true
    vim.schedule(function()
      if opts.on_tool_use then
        if type(input.file_paths) == "table" and #input.file_paths > 0 then
          for _, path in ipairs(input.file_paths) do
            opts.on_tool_use(name, path, input.command)
          end
        else
          -- NotebookEdit carries its path as notebook_path, not file_path (request_diff.lua's
          -- own TOOL_PATH_KEYS agrees) -- without this fallback modified_file_paths never learns
          -- about a notebook edit.
          opts.on_tool_use(name, input.file_path or input.notebook_path, input.command)
        end
      end
      if opts.on_tool_use_full then
        opts.on_tool_use_full(name, input)
      end
    end)
  end
end

handlers.tool_end = function(event, context)
  local tool = event.id and tools(context)[event.id]
  if not tool then
    return
  end
  close_thinking(context)

  local name, input = tool.name, tool.input
  local marker = ToolDisplay.resolve_marker(name, ToolDisplay.get_cached_markers(context))
  local header = string.format("\n%s %s(%s)\n", marker, name, input_summary(name, input))

  if SubagentMarker.is_subagent_tool(name) then
    require("vibing.infrastructure.adapter.modules.turn_registry").decrement_subagent_count(context.turnId)
  end

  -- Anything the subagent said arrived while this tool was running; show it between the header
  -- and the result, so the reasoning appears before the conclusion it produced.
  local buffered = context._subagent_text and context._subagent_text[event.id]
  if buffered then
    context._subagent_text[event.id] = nil
    header = header .. SubagentDisplay.format_buffer(input.subagent_type, buffered, SubagentDisplay.get_cached_show_prefix(context))
  end

  local result_text = type(event.result) == "string" and event.result or ""
  if event.is_error and result_text ~= "" and not result_text:match("^Error: ") then
    result_text = "Error: " .. result_text
  end

  local result_display = ToolDisplay.format_result_text(result_text, ToolDisplay.get_cached_display_mode(context))
  emit(header .. result_display .. SubagentMarker.for_tool_result(name, input, result_text), context)

  tools(context)[event.id] = nil
end

handlers.subagent_text = function(event, context)
  if not event.parent_id or not event.text or event.text == "" then
    return
  end
  context._subagent_text = context._subagent_text or {}
  context._subagent_text[event.parent_id] = (context._subagent_text[event.parent_id] or "") .. event.text
end

handlers.usage = function(event, context)
  if event.accumulator ~= nil then
    context.tokenUsage = event.accumulator
    return
  end
  if event.record == nil then
    return
  end
  context.tokenUsage = context.tokenUsage or TokenUsage.new()
  TokenUsage.record(context.tokenUsage, event.record, event.subagent == true)
end

--- @param value any
--- @return number|nil
local function as_count(value)
  return type(value) == "number" and value or nil
end

handlers.cli_info = function(event, context)
  context.cliInfo = context.cliInfo or {}
  local info = context.cliInfo
  info.version = type(event.version) == "string" and event.version or info.version
  info.model = type(event.model) == "string" and event.model or info.model
  info.tools = as_count(event.tools) or info.tools
  info.mcp_servers = as_count(event.mcp_servers) or info.mcp_servers
  if event.compacted then
    info.compacted = true
  end
  -- When the turn *began*, which is not when it ends. The cache TTL is measured from the last
  -- turn's end to this turn's first request, so timing this at the end would add the turn's own
  -- duration to the gap. Set once, so a later init cannot move it.
  if event.version or event.model then
    info.started_at = info.started_at or os.time()
  end
end

handlers.rate_limit = function(event, context)
  if not event.info then
    return
  end
  local RateLimit = require("vibing.core.utils.rate_limit")
  local previous = context.rateLimitInfo
  -- Merged newest-first: a warning may carry a reset time the rejection that ends the turn omits.
  context.rateLimitInfo = previous and RateLimit.merge(event.info, previous) or event.info
end

handlers.error = function(event, context)
  local message = event.message
  if type(message) ~= "string" or message == "" then
    return
  end
  -- Some CLIs announce one failure twice (codex: `error`, then `turn.failed`), and errorOutput is
  -- concatenated with no separator, so an immediate repeat is dropped. Two identical failures
  -- further apart are both kept.
  if context._last_error_message ~= message then
    context._last_error_message = message
    table.insert(context.errorOutput, message)
  end
  if event.fatal then
    -- Kept apart from stderr: stderr is only a failure when the exit code says so, but this is
    -- the CLI declaring the turn failed, which can happen with the process still exiting 0.
    context.resultErrors = context.resultErrors or {}
    table.insert(context.resultErrors, message)
  end
end

--- Apply one canonical event to the stream's context.
--- @param event Vibing.CanonicalEvent
--- @param context table the adapter's event context
function M.handle(event, context)
  local handler = type(event) == "table" and handlers[event.kind]
  if handler then
    handler(event, context)
  end
end

M._input_summary = input_summary

return M
