--- The command line an `nvim_job_start` call is judged by, as `Bash`.
---
--- The argv is joined with spaces, unquoted, so a destructive pattern still sees `rm -rf /`
--- inside `bash -c`. Every `env` entry is written in front as `NAME=value`, the way Bash would
--- see it: `PATH` or `NODE_OPTIONS` decides what `npm test` actually runs, so a `Bash(npm:*)`
--- rule must not match a call that sets one.
---
--- @module vibing.infrastructure.permissions.job_command

local M = {}

local SHELL_BASENAMES = { sh = true, bash = true, zsh = true, dash = true, fish = true, ksh = true, ash = true }

local UNREADABLE = "nvim_job_start"

--- @param input table|nil
--- @return string[]|nil
local function argv_of(input)
  local command = type(input) == "table" and input.command or nil
  if type(command) ~= "table" or #command == 0 then
    return nil
  end
  for _, arg in ipairs(command) do
    if type(arg) ~= "string" or arg == "" then
      return nil
    end
  end
  return command
end

--- @param input table|nil
--- @return string never empty: an unreadable argv still has to be judged, not auto-allowed
function M.from_job(input)
  local command = type(input) == "table" and input.command or nil
  local line
  if type(command) == "string" and vim.trim(command) ~= "" then
    line = command
  else
    local argv = argv_of(input)
    if not argv then
      return UNREADABLE
    end
    line = table.concat(argv, " ")
  end
  local env = type(input.env) == "table" and input.env or {}
  local names = vim.tbl_keys(env)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local assignments = {}
  for _, name in ipairs(names) do
    table.insert(assignments, string.format("%s=%s", tostring(name), tostring(env[name])))
  end
  table.insert(assignments, line)
  return table.concat(assignments, " ")
end

--- @param arg string
--- @return string
local function quote_arg(arg)
  if arg:match("[%s;&|<>$`\\\"'%[%]%(%)#*?]") then
    return "'" .. arg:gsub("'", "'\\''") .. "'"
  end
  return arg
end

--- Command strings to scan for shell backgrounding. The joined argv is quoted so an argument
--- that merely contains `&` is not an operator; a shell's `-c` script, anywhere in the argv
--- (`sudo -u user bash -c 'sleep &'`), is returned unquoted because that script is a shell.
--- @param input table|nil
--- @return string[]
function M.background_scripts(input)
  local command = type(input) == "table" and input.command or nil
  if type(command) == "string" then
    return { command }
  end
  local argv = argv_of(input)
  if not argv then
    return {}
  end
  local scripts = { table.concat(vim.tbl_map(quote_arg, argv), " ") }
  for index, arg in ipairs(argv) do
    if SHELL_BASENAMES[arg:match("([^/]+)$") or arg] then
      for flag_at = index + 1, #argv do
        if (argv[flag_at] == "-c" or argv[flag_at] == "-lc") and argv[flag_at + 1] then
          table.insert(scripts, argv[flag_at + 1])
          break
        end
      end
    end
  end
  return scripts
end

return M
