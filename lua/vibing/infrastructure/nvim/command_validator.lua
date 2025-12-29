local M = {}

local ALLOWED_COMMANDS = {
  "edit",
  "e",
  "buffer",
  "b",
  "bnext",
  "bn",
  "bprevious",
  "bp",
  "bprev",
  "vsplit",
  "vs",
  "split",
  "sp",
  "close",
  "clo",
  "write",
  "w",
  "wq",
  "quit",
  "q",
  "tabnew",
  "tabnext",
  "tabprevious",
  "tabclose",
  "set",
  "setlocal",
  "normal",
  "norm",
}

local DANGEROUS_PATTERNS = {
  "^!",
  "^:!",
  "vim%.fn%.system",
  "vim%.fn%.jobstart",
  "vim%.fn%.termopen",
  "vim%.loop%.spawn",
  "vim%.uv%.spawn",
  "%$%(",
  "`[^`]*`",
  "|%s*!",
  "os%.execute",
  "io%.popen",
}

local SENSITIVE_PATHS = {
  "/etc/",
  "/var/",
  "/usr/",
  "/root/",
  "/home/",
  "/tmp/",
  "/bin/",
  "/sbin/",
}

local function is_allowed_command(cmd_name)
  local lower_cmd = cmd_name:lower()
  for _, allowed in ipairs(ALLOWED_COMMANDS) do
    if lower_cmd == allowed then
      return true
    end
  end
  return false
end

local function has_dangerous_pattern(command)
  for _, pattern in ipairs(DANGEROUS_PATTERNS) do
    if command:match(pattern) then
      return true, "Dangerous pattern detected: " .. pattern
    end
  end
  return false
end

local function has_path_traversal(command)
  if command:match("%.%.%/") or command:match("%.%.\\") then
    return true, "Path traversal detected"
  end
  return false
end

local function is_sensitive_path(command)
  for _, sensitive in ipairs(SENSITIVE_PATHS) do
    if command:match(sensitive) then
      return true, "Access to sensitive path: " .. sensitive
    end
  end
  return false
end

local function extract_command_name(command)
  local trimmed = command:gsub("^%s*:?%s*", "")
  local cmd_name = trimmed:match("^(%S+)")
  return cmd_name
end

function M.validate(command)
  if command == nil or command == "" then
    return false, "Empty command"
  end

  if type(command) ~= "string" then
    return false, "Command must be a string"
  end

  local is_dangerous, danger_reason = has_dangerous_pattern(command)
  if is_dangerous then
    return false, danger_reason
  end

  local has_traversal, traversal_reason = has_path_traversal(command)
  if has_traversal then
    return false, traversal_reason
  end

  local is_sensitive, sensitive_reason = is_sensitive_path(command)
  if is_sensitive then
    return false, sensitive_reason
  end

  local cmd_name = extract_command_name(command)
  if not cmd_name then
    return false, "Could not parse command"
  end

  if not is_allowed_command(cmd_name) then
    return false, "Command not in allowlist: " .. cmd_name
  end

  return true, nil
end

function M.get_allowed_commands()
  return vim.deepcopy(ALLOWED_COMMANDS)
end

return M
