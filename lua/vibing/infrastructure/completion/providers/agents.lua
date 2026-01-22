---@class Vibing.AgentsProvider
---Provides agent candidates from installed plugins
---@module "vibing.infrastructure.completion.providers.agents"
local M = {}

---@type Vibing.CompletionItem[]?
local _cache = nil

---Parse agent markdown file to extract metadata from YAML frontmatter
---@param file_path string
---@param plugin_name string
---@return {name: string, description: string, full_name: string}?
local function parse_agent(file_path, plugin_name)
  if vim.fn.filereadable(file_path) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(file_path, "", 30)
  if not lines or #lines == 0 then
    return nil
  end

  -- Check for YAML frontmatter
  if lines[1] ~= "---" then
    return nil
  end

  local name = nil
  local description = nil

  for i = 2, #lines do
    local line = lines[i]
    if line == "---" then
      break
    end

    local key, value = line:match("^(%w+):%s*(.+)$")
    if key == "name" then
      name = value
    elseif key == "description" then
      description = value
    end
  end

  if not name then
    return nil
  end

  return {
    name = name,
    description = description or name,
    full_name = plugin_name .. ":" .. name,
  }
end

---Load installed plugins from ~/.claude/plugins/installed_plugins.json
---@return {plugin_name: string, install_path: string}[]
local function load_installed_plugins()
  local plugins_file = vim.fn.expand("~/.claude/plugins/installed_plugins.json")
  if vim.fn.filereadable(plugins_file) ~= 1 then
    return {}
  end

  local content = vim.fn.readfile(plugins_file)
  if not content or #content == 0 then
    return {}
  end

  local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
  if not ok or not data or not data.plugins then
    return {}
  end

  local result = {}
  for plugin_key, versions in pairs(data.plugins) do
    -- plugin_key format: "plugin-name@publisher"
    local plugin_name = plugin_key:match("^([^@]+)@")
    if plugin_name and versions and #versions > 0 then
      -- Use the first (latest) version
      local install_path = versions[1].installPath
      if install_path then
        table.insert(result, {
          plugin_name = plugin_name,
          install_path = install_path,
        })
      end
    end
  end

  return result
end

---Scan all plugin directories for agents
---@return Vibing.CompletionItem[]
local function scan_agents()
  local items = {}
  local plugins = load_installed_plugins()

  for _, plugin in ipairs(plugins) do
    local agents_dir = plugin.install_path .. "/agents/"
    if vim.fn.isdirectory(agents_dir) == 1 then
      local agent_files = vim.fn.glob(agents_dir .. "*.md", false, true)
      for _, agent_file in ipairs(agent_files) do
        local agent = parse_agent(agent_file, plugin.plugin_name)
        if agent then
          table.insert(items, {
            word = agent.full_name,
            label = "@agent:" .. agent.full_name,
            kind = "Agent",
            description = agent.description,
            detail = "plugin:" .. plugin.plugin_name,
            source = "plugin",
            filterText = agent.full_name .. " " .. agent.name,
          })
        end
      end
    end
  end

  -- Add built-in agents
  local builtins = {
    { name = "general-purpose", description = "General-purpose agent for complex tasks" },
    { name = "Explore", description = "Fast agent for exploring codebases" },
    { name = "Plan", description = "Software architect agent for designing plans" },
  }

  for _, builtin in ipairs(builtins) do
    table.insert(items, {
      word = builtin.name,
      label = "@agent:" .. builtin.name,
      kind = "Agent",
      description = builtin.description,
      detail = "builtin",
      source = "builtin",
      filterText = builtin.name,
    })
  end

  table.sort(items, function(a, b)
    -- Sort builtins first, then by name
    if a.source ~= b.source then
      return a.source == "builtin"
    end
    return a.word < b.word
  end)

  return items
end

---Get all agent candidates (cached)
---@return Vibing.CompletionItem[]
function M.get_all()
  if not _cache then
    _cache = scan_agents()
  end
  return _cache
end

---Clear cache (call when plugins change)
function M.clear_cache()
  _cache = nil
end

return M
