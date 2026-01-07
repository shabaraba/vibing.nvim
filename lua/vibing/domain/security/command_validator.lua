---@class Vibing.CommandValidator
---Command injection attack prevention module
---Validates shell commands and arguments to prevent command injection
local M = {}

---List of dangerous shell metacharacters that can be used for injection
local SHELL_METACHARACTERS = {
  ";",   -- Command separator
  "&",   -- Background execution
  "|",   -- Pipe
  "$",   -- Variable expansion
  "`",   -- Command substitution (backtick)
  "(",   -- Subshell
  ")",   -- Subshell
  "<",   -- Input redirection
  ">",   -- Output redirection
  "\n",  -- Newline (command separator)
  "\r",  -- Carriage return
}

---Dangerous command patterns that should never be allowed
local DANGEROUS_PATTERNS = {
  "rm%s+%-rf",           -- rm -rf (destructive)
  "sudo",                -- Privilege escalation
  "su%s+",               -- User switching
  "dd%s+if=",            -- Disk duplication (dangerous)
  "mkfs",                -- Format filesystem
  "fdisk",               -- Disk partitioning
  "wget.*%.sh",          -- Download and potentially execute scripts
  "curl.*%.sh",          -- Download and potentially execute scripts
  "eval%s+",             -- Code evaluation
  "exec%s+",             -- Code execution
  "source%s+",           -- Source script
  "%$%(.*%)",            -- Command substitution $(...)
  "%`.*%`",              -- Command substitution `...`
}

---Check if a string contains shell metacharacters
---@param str string String to check
---@return boolean contains True if string contains metacharacters
---@return string|nil character The first dangerous character found
function M.contains_metacharacters(str)
  if not str or str == "" then
    return false, nil
  end

  for _, char in ipairs(SHELL_METACHARACTERS) do
    if str:find(char, 1, true) then  -- plain text search
      return true, char
    end
  end

  return false, nil
end

---Check if a command matches dangerous patterns
---@param cmd string Command to check
---@return boolean dangerous True if command matches dangerous patterns
---@return string|nil pattern The first dangerous pattern found
function M.matches_dangerous_pattern(cmd)
  if not cmd or cmd == "" then
    return false, nil
  end

  -- Convert to lowercase for case-insensitive matching
  local cmd_lower = cmd:lower()

  for _, pattern in ipairs(DANGEROUS_PATTERNS) do
    if cmd_lower:match(pattern) then
      return true, pattern
    end
  end

  return false, nil
end

---Validate a shell command for safety
---@param cmd string Command to validate
---@return boolean valid True if command is safe
---@return string|nil error Error message if validation failed
function M.validate_command(cmd)
  if not cmd or cmd == "" then
    return false, "Empty command"
  end

  -- Check for metacharacters
  local has_meta, char = M.contains_metacharacters(cmd)
  if has_meta then
    return false, string.format("Command contains dangerous metacharacter: '%s'", char)
  end

  -- Check for dangerous patterns
  local is_dangerous, pattern = M.matches_dangerous_pattern(cmd)
  if is_dangerous then
    return false, string.format("Command matches dangerous pattern: %s", pattern)
  end

  return true, nil
end

---Validate command arguments for safety
---Each argument is checked individually for metacharacters
---@param args string[] List of command arguments
---@return boolean valid True if all arguments are safe
---@return string|nil error Error message if validation failed
function M.validate_arguments(args)
  if not args then
    return true, nil  -- No arguments is safe
  end

  for i, arg in ipairs(args) do
    local has_meta, char = M.contains_metacharacters(arg)
    if has_meta then
      return false, string.format("Argument %d contains dangerous metacharacter: '%s'", i, char)
    end
  end

  return true, nil
end

---Validate a complete command with arguments
---@param cmd string Command name
---@param args? string[] Command arguments
---@return boolean valid True if command and arguments are safe
---@return string|nil error Error message if validation failed
function M.validate_full_command(cmd, args)
  -- Validate command
  local cmd_valid, cmd_err = M.validate_command(cmd)
  if not cmd_valid then
    return false, cmd_err
  end

  -- Validate arguments if provided
  if args then
    local args_valid, args_err = M.validate_arguments(args)
    if not args_valid then
      return false, args_err
    end
  end

  return true, nil
end

---Check if a command is in an allowlist of safe commands
---@param cmd string Command to check
---@param allowlist string[] List of allowed command names
---@return boolean allowed True if command is in allowlist
function M.is_allowed_command(cmd, allowlist)
  if not cmd or cmd == "" then
    return false
  end

  if not allowlist or #allowlist == 0 then
    -- No allowlist means we rely on other validation methods
    return true
  end

  -- Extract command name (first word)
  local cmd_name = cmd:match("^%s*(%S+)")
  if not cmd_name then
    return false
  end

  -- Check if command is in allowlist
  for _, allowed in ipairs(allowlist) do
    if cmd_name == allowed then
      return true
    end
  end

  return false
end

---Escape a string for safe use in shell commands using Neovim's built-in function
---This should only be used as a last resort - prefer using proper argument arrays
---Uses vim.fn.shellescape() which handles different shells correctly (bash, zsh, fish, etc.)
---@param str string String to escape
---@return string escaped Escaped string safe for shell use
function M.escape_for_shell(str)
  if not str or str == "" then
    return ""
  end

  -- Use Neovim's built-in shellescape which handles different shells correctly
  return vim.fn.shellescape(str)
end

return M
