--- Put the user's Codex provider back on a lightweight call.
---
--- Lightweight calls run with `--ignore-user-config` because that is the only flag that keeps
--- them out of the user's MCP servers (`codex_command_builder.lua`). The same flag drops
--- `model_provider` and `model`, so a title or summary was sent to Codex's compiled-in OpenAI
--- default even when ordinary chat used a custom or local provider (#925).
---
--- Codex will report the provider's name (`codex doctor`) and not its definition, and project
--- `.codex/config.toml` is not allowed to set `model_provider` at all. The definition therefore
--- comes from `$CODEX_HOME/config.toml` (or `~/.codex/config.toml`). Only the top-level
--- `model_provider`, `model` and `openai_base_url` keys, plus the selected
--- `[model_providers.<id>]` table, are copied back as `-c` overrides. Everything else in the
--- file — MCP servers, profiles, hooks — stays out.
---
--- vibing.nvim does not pass `--profile`, and neither does this copy: an ordinary chat resolves
--- the same top-level keys. A provider id that cannot be a bare `-c` key is left alone, and the
--- existing doctor warning still describes that call.
---
--- @module vibing.infrastructure.adapter.modules.codex_lightweight_provider

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local Toml = require("vibing.core.utils.toml")

local M = {}

--- A config past this is not a provider definition; skip the copy rather than stall a title.
local MAX_BYTES = 512 * 1024

--- Codex's own default. Naming it explicitly changes nothing, so it is not re-sent.
local DEFAULT_PROVIDER = "openai"

--- Sentinel for "do not read a config file" (`_set_config_path(false)`). Distinct from nil,
--- which means the real `$CODEX_HOME/config.toml`.
local NO_FILE = {}

--- @type string|table|nil
local path_override

--- @type { path: string, lines: string[], parsed: table }|nil
local cache

--- Forget a test override and the parsed file. Test seam: the cache is process-wide.
function M._reset()
  path_override = nil
  cache = nil
end

--- Point the next read at `path`, or at nothing when `path` is false.
--- @param path string|false
function M._set_config_path(path)
  path_override = path == false and NO_FILE or path
  cache = nil
end

--- @param line string
--- @param target string
--- @return number|nil
local function find_unquoted_char(line, target)
  local quote = nil
  local escaped = false
  for i = 1, #line do
    local char = line:sub(i, i)
    if quote == '"' then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == quote then
        quote = nil
      end
    elseif quote == "'" then
      if char == quote then
        quote = nil
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char == target then
      return i
    end
  end
  return nil
end

--- @param line string
--- @return string
local function strip_comment(line)
  local index = find_unquoted_char(line, "#")
  return index and line:sub(1, index - 1) or line
end

--- @param raw string
--- @return string|nil
local function decode_quoted_key(raw)
  if raw:sub(1, 1) == "'" then
    local body = raw:sub(2, -2)
    if body:find("'", 1, true) then
      return nil
    end
    return body
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "string" then
    return nil
  end
  return decoded
end

--- A dotted TOML key, or nil when the line is not one this copy can re-emit.
--- @param source string
--- @return string[]|nil
local function parse_key(source)
  local parts = {}
  local index = 1
  local length = #source

  local function skip_space()
    while index <= length and source:sub(index, index):match("%s") do
      index = index + 1
    end
  end

  while true do
    skip_space()
    if index > length then
      return nil
    end
    local char = source:sub(index, index)
    local segment
    if char == '"' or char == "'" then
      local quote = char
      local start = index
      local escaped = false
      index = index + 1
      while index <= length do
        char = source:sub(index, index)
        if quote == '"' and escaped then
          escaped = false
        elseif quote == '"' and char == "\\" then
          escaped = true
        elseif char == quote then
          break
        end
        index = index + 1
      end
      if index > length or source:sub(index, index) ~= quote then
        return nil
      end
      segment = decode_quoted_key(source:sub(start, index))
      if not segment then
        return nil
      end
      index = index + 1
    else
      local start = index
      while index <= length and source:sub(index, index):match("[%w_%-]") do
        index = index + 1
      end
      segment = source:sub(start, index - 1)
      if segment == "" then
        return nil
      end
    end
    table.insert(parts, segment)
    skip_space()
    if index > length then
      return parts
    end
    if source:sub(index, index) ~= "." then
      return nil
    end
    index = index + 1
  end
end

--- @param raw string
--- @return string|nil
local function decode_string(raw)
  if type(raw) ~= "string" or #raw < 2 then
    return nil
  end
  local quote = raw:sub(1, 1)
  if raw:sub(-1) ~= quote or (quote ~= '"' and quote ~= "'") then
    return nil
  end
  if quote == "'" then
    local body = raw:sub(2, -2)
    if body:find("'", 1, true) then
      return nil
    end
    return body
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "string" then
    return decoded
  end
  return nil
end

--- @param segments string[]
--- @return boolean
local function bare_path(segments)
  for _, segment in ipairs(segments) do
    if not Toml.is_bare_key(segment) then
      return false
    end
  end
  return #segments > 0
end

--- @param lines string[]
--- @return table
local function parse_lines(lines)
  local root = {}
  local fields = {}
  local section = {}
  local ignore_section = false

  for index, original in ipairs(lines) do
    local line = original
    if index == 1 then
      line = line:gsub("^\239\187\191", "")
    end
    line = vim.trim(strip_comment(line))
    if line ~= "" then
      if line:sub(1, 2) == "[[" then
        ignore_section = true
        section = {}
      elseif line:sub(1, 1) == "[" and line:sub(-1) == "]" then
        local parsed = parse_key(vim.trim(line:sub(2, -2)))
        if parsed then
          section = parsed
          ignore_section = false
        else
          ignore_section = true
          section = {}
        end
      elseif not ignore_section then
        local equals = find_unquoted_char(line, "=")
        if equals then
          local key = parse_key(vim.trim(line:sub(1, equals - 1)))
          local raw = vim.trim(line:sub(equals + 1))
          if key and raw ~= "" and not raw:find("[\r\n]") then
            local full = {}
            for _, part in ipairs(section) do
              table.insert(full, part)
            end
            for _, part in ipairs(key) do
              table.insert(full, part)
            end
            if #section == 0 and #full == 1 then
              root[full[1]] = raw
            elseif full[1] == "model_providers" and bare_path(full) then
              fields[table.concat(full, ".")] = raw
            end
          end
        end
      end
    end
  end

  return { root = root, fields = fields }
end

--- @return table|nil
local function read_config()
  local path = nil
  if path_override == NO_FILE then
    return nil
  elseif type(path_override) == "string" and path_override ~= "" then
    path = path_override
  else
    local home = vim.fn.environ().CODEX_HOME
    if type(home) ~= "string" or home == "" then
      home = vim.fn.expand("~/.codex")
    end
    home = tostring(home):gsub("[/\\]+$", "")
    if home == "" then
      return nil
    end
    path = home .. "/config.toml"
  end

  local size = vim.fn.getfsize(path)
  if type(size) ~= "number" or size < 0 or size > MAX_BYTES then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  if cache and cache.path == path and vim.deep_equal(cache.lines, lines) then
    return cache.parsed
  end
  local parsed = parse_lines(lines)
  cache = { path = path, lines = lines, parsed = parsed }
  return parsed
end

--- @param args string[]
--- @param key string
--- @param raw string
local function append_override(args, key, raw)
  table.insert(args, "-c")
  table.insert(args, key .. "=" .. raw)
end

--- `-c` overrides that put the configured provider and model back on one lightweight call.
---
--- `model` is included only when this call is not already passing `-m`. A configured
--- `ai.helpers.model` (anything other than a Claude short name) wins; otherwise the model is
--- the one `config.toml` gives an ordinary call that also passes no `-m`.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.args(ctx)
  local parsed = read_config()
  if not parsed then
    return {}
  end

  local provider = decode_string(parsed.root.model_provider or "")
  if provider == "" then
    provider = nil
  end
  local args = {}

  if provider and provider ~= DEFAULT_PROVIDER and Toml.is_bare_key(provider) then
    append_override(args, "model_provider", Toml.string(provider))
    local prefix = "model_providers." .. provider
    local keys = {}
    for key in pairs(parsed.fields) do
      if key == prefix or key:sub(1, #prefix + 1) == prefix .. "." then
        table.insert(keys, key)
      end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      append_override(args, key, parsed.fields[key])
    end
  end

  local base_url = decode_string(parsed.root.openai_base_url or "")
  if base_url and base_url ~= "" then
    append_override(args, "openai_base_url", Toml.string(base_url))
  end

  if not NonClaudeModel.resolve(ctx.opts, ctx.config) then
    local model = decode_string(parsed.root.model or "")
    if model and model ~= "" then
      append_override(args, "model", Toml.string(model))
    end
  end

  return args
end

return M
