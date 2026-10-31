--- Shell commands that reach Neovim through an MCP tool instead of the Bash tool.
---
--- `can_use_tool` judges the string returned here as `Bash`, so allow, deny, ask, and the
--- destructive-command rules apply to it. `nil` means the call is not a shell invocation.
---
--- Covered: `:!` and `:[range]!` (including modifiers such as `:silent`), `:terminal`,
--- `:read !` / `:write !` (a bang after `++opt` too), `:tab` / `:debug` wrapping one of those,
--- `:execute` of a literal, `:make` / `:lmake` / `:grep` / `:lgrep` / `:grepadd` / `:lgrepadd`,
--- `|`-chained commands, and direct calls to `system` / `systemlist` / `jobstart` / `termopen` /
--- `os.execute` / `io.popen` / `vim.system` / `vim.uv.spawn` / `vim.loop.spawn` from `:lua`,
--- `:call`, `:echo`, `:let`, and similar. `:python` / `:perl` / `:ruby` / `:tcl` are treated as
--- shell interpreters. `nvim_job_start` is always a shell command: its argv is joined with spaces
--- so the existing Bash matchers see one command line.
---
--- Not covered, and still able to run a shell when Bash rules would refuse the literal form:
--- a command built at runtime (`:execute` of a variable, `vim.cmd(cmd)`, concatenation, `load`),
--- `:source` / `:luafile` of a file that calls one of the functions above, `'makeprg'` /
--- `'grepprg'` / `'shell'` after they have been pointed at something else (`:make` is judged as
--- the text `make …`, not the expanded program), and an argv element that is itself a shell
--- snippet unless the executable is a shell and the snippet is its `-c` argument.
---
--- @module vibing.infrastructure.permissions.shell_command

local M = {}

local MAX_DEPTH = 8

--- Ex commands whose arguments are a shell program, or which run one through 'makeprg' / 'grepprg'.
local SHELL_EX = {
  make = true,
  lmake = true,
  grep = true,
  lgrep = true,
  grepadd = true,
  lgrepadd = true,
}

--- Embedded interpreters. Parsing succeeds even when the provider is not compiled in; the
--- permission decision has to be the same either way.
local INTERPRETERS = {
  python = true,
  python3 = true,
  pythonx = true,
  py3 = true,
  py = true,
  pydo = true,
  perl = true,
  ruby = true,
  tcl = true,
  mzscheme = true,
}

local SHELL_BASENAMES = {
  sh = true,
  bash = true,
  zsh = true,
  dash = true,
  fish = true,
  ksh = true,
  ash = true,
}

local QUOTED_CALLS = {
  "systemlist%s*%(%s*",
  "system%s*%(%s*",
  "os%.execute%s*%(%s*",
  "io%.popen%s*%(%s*",
  "jobstart%s*%(%s*",
  "termopen%s*%(%s*",
  "vim%.uv%.spawn%s*%(%s*",
  "vim%.loop%.spawn%s*%(%s*",
  "uv%.spawn%s*%(%s*",
  "loop%.spawn%s*%(%s*",
}

local TABLE_CALLS = {
  "systemlist",
  "system",
  "jobstart",
  "vim%.uv%.spawn",
  "vim%.loop%.spawn",
}

local EX_LITERALS = {
  "vim%.cmd%s*%(%s*",
  "nvim_exec2%s*%(%s*",
  "nvim_exec%s*%(%s*",
  "nvim_command%s*%(%s*",
  "nvim_feedkeys%s*%(%s*",
  "feedkeys%s*%(%s*",
}

local OPAQUE_CALLS = {
  "%f[%w]systemlist%s*%(",
  "%f[%w]system%s*%(",
  "os%.execute%s*%(",
  "io%.popen%s*%(",
  "%f[%w]jobstart%s*%(",
  "%f[%w]termopen%s*%(",
  "vim%.system%s*%(",
  "vim%.uv%.spawn%s*%(",
  "vim%.loop%.spawn%s*%(",
}

local parse_ex
local expression_shell

local function join_args(args)
  if type(args) ~= "table" then
    return ""
  end
  return vim.trim(table.concat(args, " "))
end

local function unquote(text)
  local trimmed = vim.trim(text)
  local quote = trimmed:match("^([\"'])")
  if not quote then
    return trimmed
  end
  return trimmed:match("^" .. quote .. "(.*)" .. quote .. "$") or trimmed
end

local function without_next(command, nextcmd)
  if type(nextcmd) ~= "string" or nextcmd == "" then
    return command
  end
  local at = command:find("|%s*" .. vim.pesc(nextcmd) .. "%s*$")
  if not at then
    return command
  end
  return command:sub(1, at - 1)
end

--- `:read !cmd` / `:write !cmd`, including `:write ++ff=unix !cmd`. `:write!` is force-write and
--- has no bang in the argument text, so it is not a shell command.
--- @param args string[]
--- @return string|nil
local function read_write_shell(args)
  local text = join_args(args)
  local cmd = text:match("^%s*!%s*(.*)$") or text:match("%s!%s*(.*)$")
  if not cmd then
    return nil
  end
  cmd = vim.trim(cmd)
  if cmd == "" then
    return "!"
  end
  return cmd
end

local function add_part(parts, command)
  if type(command) == "string" and vim.trim(command) ~= "" then
    table.insert(parts, vim.trim(command))
  end
end

local function collect_quoted(text, func_pattern, into)
  local pattern = func_pattern .. "([\"'])(.-)%1"
  local start_at = 1
  while start_at <= #text do
    local found, stop, _, lit = text:find(pattern, start_at)
    if not found then
      break
    end
    if lit and lit ~= "" then
      table.insert(into, lit)
    end
    start_at = stop + 1
  end
end

local function collect_argv_tables(text, func_pattern, into)
  local pattern = func_pattern .. "%s*%(%s*{(.-)}"
  local start_at = 1
  while start_at <= #text do
    local found, stop, body = text:find(pattern, start_at)
    if not found then
      break
    end
    local args = {}
    for lit in body:gmatch("[\"']([^\"']*)[\"']") do
      if lit ~= "" then
        table.insert(args, lit)
      end
    end
    if #args > 0 then
      table.insert(into, table.concat(args, " "))
    end
    start_at = stop + 1
  end
end

local function collect_ex_literals(text, depth, into)
  for _, func_pattern in ipairs(EX_LITERALS) do
    local pattern = func_pattern .. "([\"'])(.-)%1"
    local start_at = 1
    while start_at <= #text do
      local found, stop, _, lit = text:find(pattern, start_at)
      if not found then
        break
      end
      add_part(into, parse_ex(lit, depth + 1))
      start_at = stop + 1
    end
  end
end

local function has_opaque_call(text)
  for _, pattern in ipairs(OPAQUE_CALLS) do
    if text:find(pattern) then
      return true
    end
  end
  return false
end

expression_shell = function(text, depth)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil
  end
  local parts = {}
  collect_ex_literals(text, depth, parts)
  for _, func_pattern in ipairs(QUOTED_CALLS) do
    collect_quoted(text, func_pattern, parts)
  end
  for _, func_pattern in ipairs(TABLE_CALLS) do
    collect_argv_tables(text, "%f[%w]" .. func_pattern, parts)
  end
  if #parts > 0 then
    return table.concat(parts, " && ")
  end
  if has_opaque_call(text) then
    return text
  end
  return nil
end

--- @param parsed table
--- @param command string the ex command that parsed into `parsed`, without a trailing `|` chain
--- @param depth number
--- @return string|nil
local function direct_shell(parsed, command, depth)
  if parsed.cmd == "!" then
    local joined = join_args(parsed.args)
    if joined == "" then
      return "!"
    end
    return joined
  end

  if parsed.cmd == "terminal" then
    local joined = join_args(parsed.args)
    if joined == "" then
      return "terminal"
    end
    return joined
  end

  if SHELL_EX[parsed.cmd] then
    local joined = join_args(parsed.args)
    if joined == "" then
      return parsed.cmd
    end
    return parsed.cmd .. " " .. joined
  end

  if INTERPRETERS[parsed.cmd] then
    -- Prefer a literal the body hands to a shell, so `os.system('rm -rf /')` is judged as that
    -- command. A body with no recognizable call is still a shell: the whole invocation is.
    return expression_shell(command, depth) or vim.trim(command)
  end

  if parsed.cmd == "read" or parsed.cmd == "write" then
    return read_write_shell(parsed.args)
  end

  if parsed.cmd == "execute" or parsed.cmd == "tab" or parsed.cmd == "debug" then
    local inner = join_args(parsed.args)
    if parsed.cmd == "execute" then
      inner = unquote(inner)
    end
    if inner == "" then
      return nil
    end
    return parse_ex(inner, depth + 1)
  end

  return nil
end

parse_ex = function(command, depth)
  if type(command) ~= "string" then
    return nil
  end
  command = vim.trim(command)
  if command == "" then
    return nil
  end
  if depth > MAX_DEPTH then
    return command
  end

  local ok, parsed = pcall(vim.api.nvim_parse_cmd, command, {})
  if not ok then
    return expression_shell(command, depth)
  end

  local current = without_next(command, parsed.nextcmd)
  local parts = {}
  add_part(parts, direct_shell(parsed, current, depth))
  if #parts == 0 then
    add_part(parts, expression_shell(current, depth))
  end
  if parsed.nextcmd and parsed.nextcmd ~= "" then
    add_part(parts, parse_ex(parsed.nextcmd, depth + 1))
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " && ")
end

--- @param command string|nil
--- @return string|nil shell command to judge as Bash, or nil when the Ex command runs no shell
function M.from_ex(command)
  return parse_ex(command, 0)
end

--- @param input table|nil
--- @return string command line. Always a string: an unreadable argv still has to be judged, and
---   an empty result would let the MCP auto-allow through.
function M.from_job(input)
  local command = type(input) == "table" and input.command or nil
  if type(command) == "string" and vim.trim(command) ~= "" then
    return command
  end
  if type(command) ~= "table" or #command == 0 then
    return "nvim_job_start"
  end
  local parts = {}
  for _, arg in ipairs(command) do
    if type(arg) ~= "string" or arg == "" then
      return "nvim_job_start"
    end
    table.insert(parts, arg)
  end
  return table.concat(parts, " ")
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

--- Quote only arguments that would change the backgrounding scan. The permission command line
--- stays unquoted (`from_job`) so a destructive pattern still sees `rm -rf /` inside `bash -c`.
--- @param arg string
--- @return string
local function quote_arg(arg)
  if arg:match("[%s;&|<>$`\\\"'`%[%]%(%)#*?]") or arg == "" then
    return "'" .. arg:gsub("'", "'\\''") .. "'"
  end
  return arg
end

--- Command strings to run through `uses_shell_backgrounding`. The joined argv is quoted so an
--- argument that merely contains `&` is not a shell operator; a shell `-c` script is returned
--- unquoted because that script is a shell.
--- @param input table|nil
--- @return string[]
function M.job_background_commands(input)
  local command = type(input) == "table" and input.command or nil
  if type(command) == "string" then
    return { command }
  end
  if type(command) ~= "table" then
    return {}
  end

  local argv = {}
  for _, arg in ipairs(command) do
    if type(arg) ~= "string" then
      return {}
    end
    table.insert(argv, arg)
  end
  if #argv == 0 then
    return {}
  end

  local quoted = {}
  for _, arg in ipairs(argv) do
    table.insert(quoted, quote_arg(arg))
  end
  local scripts = { table.concat(quoted, " ") }

  -- Any shell in the argv, not only argv[1]. `sudo -u user bash -c 'sleep &'` is still a shell
  -- script; stopping at sudo's own flag would miss it. The script is what backgrounding scans.
  for index, arg in ipairs(argv) do
    if SHELL_BASENAMES[basename(arg)] then
      for flag_at = index + 1, #argv do
        local flag = argv[flag_at]
        if flag == "-c" or flag == "-lc" then
          local script = argv[flag_at + 1]
          if type(script) == "string" then
            table.insert(scripts, script)
          end
          break
        end
      end
    end
  end

  return scripts
end

return M
