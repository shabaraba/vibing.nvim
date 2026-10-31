--- Shell commands named inside a Vimscript or Lua expression (`:lua`, `:call`, `:echo`, `:let`).
---
--- A call whose whole argument is one literal (`system('ls')`, `vim.system({'ls'})`) is judged
--- as that literal. Any other mention of a process-starting name — a variable argument, a
--- concatenation, `vim.fn['system']`, `local s = vim.fn.system` — makes the whole expression the
--- command, so a Bash prefix rule cannot match it and a Bash denial still does.
---
--- @module vibing.infrastructure.permissions.shell_expression

local M = {}

local SHELL_CALLS = { "systemlist", "system", "os%.execute", "io%.popen", "jobstart", "termopen", "vim%.system" }

local EX_CALLS = { "vim%.cmd", "nvim_exec2", "nvim_exec", "nvim_command", "nvim_feedkeys", "nvim_input", "feedkeys" }

local SHELL_WORDS = {
  "%f[%w_]systemlist%f[^%w_]",
  "%f[%w_]system%f[^%w_]",
  "%f[%w_]popen%f[^%w_]",
  "%f[%w_]execute%f[^%w_]",
  "%f[%w_]jobstart%f[^%w_]",
  "%f[%w_]termopen%f[^%w_]",
  "%f[%w_]spawn%f[^%w_]",
  "%f[%w_]terminal%f[^%w_]",
  "term://",
  "%f[%w_]shell%w*",
  "%w+prg%f[^%w_]",
  "%f[%w_]nvim_exec",
  "%f[%w_]nvim_command%f[^%w_]",
  "%f[%w_]nvim_input%f[^%w_]",
  "%f[%w_]feedkeys%f[^%w_]",
  "%f[%w_]nvim_cmd%f[^%w_]",
  "vim%.cmd%s*[%(\"'%[{]",
  "[\"'%[]%s*!",
}

local LITERAL = { "\"([^\"]*)\"", "'([^']*)'" }

--- @param body string the text between the brackets of a list argument
--- @return string|nil the literals joined by spaces, or nil when an element is not a literal
local function literal_list(body)
  local items = {}
  local rest = body:gsub("[\"']([^\"']*)[\"']", function(item)
    table.insert(items, item)
    return ""
  end)
  if #items == 0 or not rest:match("^[%s,]*$") then
    return nil
  end
  return table.concat(items, " ")
end

--- Remove every `name(<literal>)` call from `text`, handing each literal to `found`.
local function strip_calls(text, name, found)
  for _, literal in ipairs(LITERAL) do
    text = text:gsub("%f[%w_]" .. name .. "%s*%(%s*" .. literal .. "%s*([,)])", function(lit, close)
      found(lit)
      return close == "," and "(" or ""
    end)
  end
  return text:gsub("%f[%w_]" .. name .. "%s*%(%s*[{%[]([^{}%[%]]*)[}%]]%s*([,)])", function(body, close)
    local joined = literal_list(body)
    if not joined then
      return nil
    end
    found(joined)
    return close == "," and "(" or ""
  end)
end

--- @param text string an expression, or an Ex command's argument text
--- @param parse_ex fun(command: string): string|nil judges an Ex literal handed to vim.cmd and kin
--- @return string|nil
function M.shell(text, parse_ex)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return nil
  end
  local parts = {}
  local rest = text
  for _, name in ipairs(SHELL_CALLS) do
    rest = strip_calls(rest, name, function(lit)
      table.insert(parts, vim.trim(lit) ~= "" and lit or name)
    end)
  end
  for _, name in ipairs(EX_CALLS) do
    rest = strip_calls(rest, name, function(lit)
      local inner = parse_ex(lit)
      if inner then
        table.insert(parts, inner)
      end
    end)
  end
  for _, word in ipairs(SHELL_WORDS) do
    if rest:find(word) then
      return vim.trim(text)
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " && ")
end

return M
