--- The OpenCode CLI's tool names and input shape, translated to the canonical vocabulary.
--- @module vibing.infrastructure.adapter.modules.opencode_tool_vocabulary

local tools_constants = require("vibing.core.constants.tools")

local M = {}

--- Configured MCP server names, registered by `opencode_config` / `opencode_mcp_config` before the
--- turn. OpenCode names an MCP tool `<server>_<tool>`, and a server name may itself contain `_`, so
--- the split cannot be guessed from the tool name alone.
--- @type table<string, boolean>
local mcp_server_names = {}

--- @param names string[]
function M.set_mcp_servers(names)
  mcp_server_names = {}
  for _, name in ipairs(names or {}) do
    if type(name) == "string" and name ~= "" then
      mcp_server_names[name] = true
    end
  end
end

--- The longest configured server name that prefixes this tool name.
--- @param native_tool_name string
--- @return string|nil
local function configured_server(native_tool_name)
  local best
  for server in pairs(mcp_server_names) do
    if native_tool_name:sub(1, #server + 1) == server .. "_" and (not best or #server > #best) then
      best = server
    end
  end
  return best
end

local NATIVE_TO_CANONICAL = {
  shell = "Bash",
  read = "Read",
  write = "Write",
  edit = "Edit",
  patch = "Edit",
  glob = "Glob",
  grep = "Grep",
  webfetch = "WebFetch",
  websearch = "WebSearch",
  skill = "Skill",
  subagent = "Task",
  question = "AskUserQuestion",
  todowrite = "TodoWrite",
}

function M.to_canonical(native_tool_name)
  if type(native_tool_name) ~= "string" then
    return nil
  end
  if NATIVE_TO_CANONICAL[native_tool_name] then
    return NATIVE_TO_CANONICAL[native_tool_name]
  end
  if native_tool_name == "opencode_worktree_create" then
    return "Bash"
  end
  if native_tool_name == "opencode_worktree_remove" then
    return "Edit"
  end
  if native_tool_name:match("^opencode_") then
    return nil
  end
  if native_tool_name:match("^experimental_") then
    return nil
  end
  local tool = native_tool_name:match("^vibing%-nvim_(.+)$")
  if tool then
    return "mcp__vibing-nvim__" .. tool
  end
  local configured = configured_server(native_tool_name)
  if configured then
    return "mcp__" .. configured .. "__" .. native_tool_name:sub(#configured + 2)
  end
  local server, suffix = native_tool_name:match("^(.-)_(.+)$")
  if server and suffix and not native_tool_name:match("^mcp__") then
    return "mcp__" .. server .. "__" .. suffix
  end
  if tools_constants.VALID_TOOLS_MAP[native_tool_name] then
    return native_tool_name
  end
  return nil
end

function M.normalize_payload(hook_input)
  if type(hook_input) ~= "table" or hook_input.tool_name ~= nil then
    return hook_input
  end
  if hook_input.tool == nil then
    return hook_input
  end
  return vim.tbl_extend("force", hook_input, {
    tool_name = hook_input.tool,
    tool_input = hook_input.input or {},
  })
end

local function patch_paths(patch_text)
  if type(patch_text) ~= "string" then
    return nil
  end
  local lines = vim.split(vim.trim(patch_text):gsub("\r\n", "\n"), "\n", { plain = true })
  local paths, seen = {}, {}
  for _, line in ipairs(lines) do
    local path = line:match("^%*%*%* Add File: (.+)$")
      or line:match("^%*%*%* Update File: (.+)$")
      or line:match("^%*%*%* Delete File: (.+)$")
      or line:match("^%*%*%* Move to: (.+)$")
    if path and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end
  if #paths == 0 then
    return nil
  end
  return paths
end

function M.normalize_input(tool_input, tool_name)
  if type(tool_input) ~= "table" then
    return tool_input
  end
  local normalized = tool_input
  local changed = false
  if not tool_input.file_path and tool_input.path then
    normalized = vim.tbl_extend("force", {}, tool_input)
    normalized.file_path = tool_input.path
    changed = true
  end
  if tool_name == "Edit" and tool_input.patchText then
    if not changed then
      normalized = vim.tbl_extend("force", {}, tool_input)
      changed = true
    end
    local paths = patch_paths(tool_input.patchText)
    if paths then
      normalized._diff_paths = paths
    end
  end
  if not changed then
    return tool_input
  end
  return normalized
end

return M
