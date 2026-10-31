--- Shell commands an `nvim_execute` Ex command would run. `can_use_tool` judges the returned
--- string as `Bash`; `nil` means no shell was recognized.
---
--- This is a recognizer of the forms an agent writes literally, not a sandbox: `:lua` and
--- Vimscript are complete languages, so code built at runtime can always start a process.
--- Recognized: `:!`, `:[range]!`, `:terminal`, `term://` buffers, `:read !` / `:write !`,
--- `:make` / `:grep` and their l-/-add forms, `:python` and the other interpreters, a `:normal`
--- that types `:` or `!`, setting 'shell' or a `*prg` option, and calls to `system` /
--- `systemlist` / `jobstart` / `termopen` / `execute()` / `os.execute` / `io.popen` /
--- `vim.system` / `vim.uv.spawn` or to `vim.cmd` / `nvim_exec2` / `feedkeys` with a literal
--- that is itself one of these. Bodies are followed through `|`, newlines, `:execute` of a
--- literal, `:windo` and the other `*do` commands, `:global`, `:autocmd`, `:command`, `:tab`,
--- `:debug` and command modifiers. A line `nvim_parse_cmd` cannot parse, and an `:execute` of
--- anything but one literal, is judged whole.
--- Not recognized: `:source`, `:luafile`, `:runtime`, `dofile` and `require` of a file that
--- starts a process, a user command defined by a plugin, a Normal-mode filter through an
--- option set earlier, and names assembled at runtime.
---
--- @module vibing.infrastructure.permissions.shell_command

local expression = require("vibing.infrastructure.permissions.shell_expression")

local M = {}

local MAX_DEPTH = 8

local QUICKFIX_SHELL = { make = true, lmake = true, grep = true, lgrep = true, grepadd = true, lgrepadd = true }

local INTERPRETERS = {}
for _, name in ipairs({ "python", "python3", "pythonx", "py3", "pyx", "pydo", "py3do", "pyxdo", "perl", "perldo", "ruby", "rubydo", "tcl", "tcldo" }) do
  INTERPRETERS[name] = true
end

local EX_BODY = {}
for _, name in ipairs({ "windo", "bufdo", "tabdo", "argdo", "cdo", "cfdo", "ldo", "lfdo", "folddoopen", "folddoclosed", "tab", "debug" }) do
  EX_BODY[name] = true
end

local walk

local function or_name(text, name)
  return text ~= "" and text or name
end

--- The Ex command a `:global` / `:autocmd` / `:command` / `:execute` / `:*do` would run.
--- @return string|nil
local function ex_body(parsed, text)
  local cmd, args = parsed.cmd, parsed.args
  if EX_BODY[cmd] then
    return text
  end
  if cmd == "execute" then
    return text:match('^"([^"]*)"$') or text:match("^'([^']*)'$")
  end
  if cmd == "global" or cmd == "vglobal" then
    local delim = text:sub(1, 1)
    local escaped = vim.pesc(delim)
    return text:match("^" .. escaped .. "[^" .. escaped .. "]*" .. escaped .. "(.*)$")
  end
  local first
  if cmd == "autocmd" then
    first = (args[1] and vim.fn.exists("##" .. args[1]) == 0) and 4 or 3
    while args[first] and args[first]:match("^%+%+") do
      first = first + 1
    end
  elseif cmd == "command" then
    first = 1
    while args[first] and args[first]:match("^%-") do
      first = first + 1
    end
    first = first + 1
  end
  if first and args[first] then
    return table.concat(args, " ", first)
  end
  return nil
end

--- @return string|nil
local function classify(parsed, whole, depth)
  local cmd = parsed.cmd
  local text = vim.trim(table.concat(parsed.args or {}, " "))
  if cmd == "!" then
    return or_name(text, "!")
  end
  if cmd == "terminal" then
    return or_name(text, "terminal")
  end
  if QUICKFIX_SHELL[cmd] then
    return vim.trim(cmd .. " " .. text)
  end
  if INTERPRETERS[cmd] or (cmd == "normal" and text:find("[:!]")) then
    return whole
  end
  if cmd == "read" or cmd == "write" then
    local shell = text:match("^!(.*)$") or text:match("%s!(.*)$")
    if shell then
      return or_name(vim.trim(shell), "!")
    end
  end
  local separator = vim.tbl_contains(parsed.args or {}, "|") and text:match("|%s*(.*)$")
  local body = separator or ex_body(parsed, text)
  if cmd == "execute" and not body then
    return whole
  end
  local inner = body and walk(body, depth + 1)
  if inner or cmd == "help" then
    return inner
  end
  return expression.shell(text, function(literal)
    return walk(literal, depth + 1)
  end)
end

--- One line, followed through its `|` chain.
local function walk_line(line, depth)
  line = line:gsub("^[%s:]+", "")
  if line == "" or line:match('^"') then
    return nil
  end
  if depth > MAX_DEPTH then
    return line
  end
  local ok, parsed = pcall(vim.api.nvim_parse_cmd, line, {})
  if not ok then
    return line
  end
  local current = line
  if parsed.nextcmd and parsed.nextcmd ~= "" then
    current = line:sub(1, #line - #parsed.nextcmd):gsub("|%s*$", "")
  end
  local here = classify(parsed, vim.trim(current), depth)
  local after = walk(parsed.nextcmd, depth + 1)
  if here and after then
    return here .. " && " .. after
  end
  return here or after
end

--- Lines as nvim_exec2 runs them: a `<<` heredoc stays with the command that opened it.
walk = function(script, depth)
  if type(script) ~= "string" then
    return nil
  end
  local lines = vim.split(script, "\n", { plain = true })
  local parts = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local marker = line:match("=?<<%s*trim%s+(%S+)%s*$") or line:match("=?<<%s*(%S*)%s*$")
    if marker then
      marker = marker == "" and "." or marker
      local last = i
      while last < #lines and vim.trim(lines[last + 1]) ~= marker do
        last = last + 1
      end
      line = table.concat(lines, "\n", i, math.min(last + 1, #lines))
      i = last + 1
    end
    local found = walk_line(line, depth)
    if found then
      table.insert(parts, found)
    end
    i = i + 1
  end
  return #parts > 0 and table.concat(parts, " && ") or nil
end

--- @param command string|nil
--- @return string|nil shell command to judge as Bash, or nil when none was recognized
function M.from_ex(command)
  return walk(command, 0)
end

return M
