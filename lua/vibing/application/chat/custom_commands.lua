local notify = require("vibing.core.utils.notify")

---@class Vibing.CustomCommand
---@field name string
---@field description string
---@field source "project"|"user"|"plugin"
---@field file_path string
---@field content string
---@field plugin_name string?

---@class Vibing.CustomCommands
local M = {}

---@type Vibing.CustomCommand[]?
M._cache = nil

---@param file_path string
---@return string?
local function extract_plugin_name(file_path)
  local marketplace_match = file_path:match("/marketplaces/[^/]+/plugins/([^/]+)/commands/")
  if marketplace_match then
    return marketplace_match
  end

  local cache_match = file_path:match("/cache/[^/]+/([^/]+)/[^/]+/commands/")
  if cache_match then
    return cache_match
  end

  return nil
end

---@param file_path string
---@return {name: string, description: string, content: string}?
function M._parse_markdown(file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return nil
  end

  local filename = vim.fn.fnamemodify(file_path, ":t")
  local name = filename:gsub("%.md$", "")

  local description = name
  for _, line in ipairs(lines) do
    local match = line:match("^#%s+(.+)$")
    if match then
      description = match
      break
    end
  end

  local content = table.concat(lines, "\n")

  return {
    name = name,
    description = description,
    content = content,
  }
end

---@return Vibing.CustomCommand[]
function M.scan()
  local commands = {}

  local paths = {
    { dir = vim.fn.getcwd() .. "/.claude/commands/", source = "project" },
    { dir = vim.fn.expand("~/.claude/commands/"), source = "user" },
  }

  for _, path_info in ipairs(paths) do
    if vim.fn.isdirectory(path_info.dir) == 1 then
      local files = vim.fn.glob(path_info.dir .. "*.md", false, true)
      for _, file in ipairs(files) do
        local success, parsed = pcall(M._parse_markdown, file)
        if success and parsed then
          table.insert(commands, {
            name = parsed.name,
            description = parsed.description,
            source = path_info.source,
            file_path = file,
            content = parsed.content,
          })
        else
          notify.warn(string.format("Failed to parse: %s", file))
        end
      end
    end
  end

  local plugin_marketplaces = vim.fn.expand("~/.claude/plugins/marketplaces/")
  if vim.fn.isdirectory(plugin_marketplaces) == 1 then
    local marketplaces = vim.fn.glob(plugin_marketplaces .. "*", false, true)
    for _, marketplace in ipairs(marketplaces) do
      if vim.fn.isdirectory(marketplace) == 1 then
        local plugin_commands = vim.fn.glob(marketplace .. "/plugins/*/commands/*.md", false, true)
        for _, file in ipairs(plugin_commands) do
          local success, parsed = pcall(M._parse_markdown, file)
          if success and parsed then
            table.insert(commands, {
              name = parsed.name,
              description = parsed.description,
              source = "plugin",
              file_path = file,
              content = parsed.content,
              plugin_name = extract_plugin_name(file),
            })
          end
        end
      end
    end
  end

  local plugin_cache = vim.fn.expand("~/.claude/plugins/cache/")
  if vim.fn.isdirectory(plugin_cache) == 1 then
    local cache_plugin_commands = vim.fn.glob(plugin_cache .. "*/*/*/commands/*.md", false, true)
    for _, file in ipairs(cache_plugin_commands) do
      local success, parsed = pcall(M._parse_markdown, file)
      if success and parsed then
        table.insert(commands, {
          name = parsed.name,
          description = parsed.description,
          source = "plugin",
          file_path = file,
          content = parsed.content,
          plugin_name = extract_plugin_name(file),
        })
      end
    end
  end

  return commands
end

---@return Vibing.CustomCommand[]
function M.get_all()
  if not M._cache then
    M._cache = M.scan()
  end
  return M._cache
end

function M.clear_cache()
  M._cache = nil
end

return M
