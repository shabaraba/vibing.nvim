--- Records which subagent a Task/Agent call left behind, so the chat can reopen a conversation
--- with it later.
--- @module vibing.infrastructure.adapter.modules.subagent_marker

local M = {}

--- The CLI ends a resumable Agent tool result with
--- `agentId: <id> (use SendMessage with to: '<id>', ...)`.
--- Built-in one-shot agents (Explore, Plan) return no id, so they simply never match.
local AGENT_ID_PATTERN = "agentId:%s*([%w_%-]+)"

--- Matches what M.format writes, so a body can be scrubbed of them again.
local MARKER_PATTERN = "\n?<!%-%- subagent: [%w_%-]+ type=[^%s]* %-%->\n?"

--- The marker is a comment so it renders as nothing in the chat, and lives in the buffer so it is
--- saved with the file — no side-channel state to keep in sync with a conversation the user can
--- rename, fork or reopen.
--- @param agent_id string
--- @param subagent_type string|nil
--- @return string
function M.format(agent_id, subagent_type)
  return string.format("\n<!-- subagent: %s type=%s -->\n", agent_id, subagent_type or "unknown")
end

--- Whether a tool call is a subagent launcher (`Task`/`Agent`, across every backend's tool
--- vocabulary normalization). Shared by the marker below and by in-flight subagent counting
--- (`cli_event_processor.lua`, `active_stream_registry.lua`), so the two never drift apart on
--- what counts as a subagent.
--- @param tool_name string|nil
--- @return boolean
function M.is_subagent_tool(tool_name)
  return tool_name == "Task" or tool_name == "Agent"
end

--- @param tool_name string|nil
--- @param tool_input table
--- @param result_text string raw tool result, before display truncation drops the tail
--- @return string marker Empty when this result did not come from a resumable subagent
function M.for_tool_result(tool_name, tool_input, result_text)
  if not M.is_subagent_tool(tool_name) then
    return ""
  end
  if type(result_text) ~= "string" then
    return ""
  end

  local agent_id = result_text:match(AGENT_ID_PATTERN)
  if not agent_id then
    return ""
  end

  return M.format(agent_id, tool_input and tool_input.subagent_type)
end

--- Remove every marker from a chat body.
--- Used when forking: the fork diverges to a new session on its first message, but the agents
--- these markers name only exist under the original session, so offering them afterwards would
--- bind a chat to an agent whose transcript the CLI cannot find.
--- @param body string
--- @return string
function M.strip(body)
  if type(body) ~= "string" then
    return ""
  end
  return (body:gsub(MARKER_PATTERN, "\n"))
end

return M
