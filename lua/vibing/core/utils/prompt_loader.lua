---@class Vibing.Core.Utils.PromptLoader

local M = {}

---@param template string
---@param replacements table<string, string>
---@return string
local function substitute_variables(template, replacements)
  local result = template
  for key, value in pairs(replacements) do
    local pattern = "{{" .. key .. "}}"
    result = result:gsub(pattern:gsub("%-", "%%-"), value)
  end
  return result
end

---@return string|nil
local function get_plugin_root()
  local runtime_paths = vim.api.nvim_list_runtime_paths()
  for _, path in ipairs(runtime_paths) do
    if path:match("vibing%.nvim/?$") then
      return path
    end
  end
  return nil
end

---@param prompt_name string
---@param replacements? table<string, string>
---@return string|nil content
---@return string|nil error
function M.load(prompt_name, replacements)
  replacements = replacements or {}

  local plugin_root = get_plugin_root()
  if not plugin_root then
    return nil, "Could not find vibing.nvim plugin directory"
  end

  local prompt_file = plugin_root .. "/prompts/" .. prompt_name .. ".md"

  if vim.fn.filereadable(prompt_file) ~= 1 then
    return nil, string.format("Prompt file not found: %s", prompt_file)
  end

  local file = io.open(prompt_file, "r")
  if not file then
    return nil, string.format("Failed to open prompt file: %s", prompt_file)
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return nil, string.format("Prompt file is empty: %s", prompt_file)
  end

  return substitute_variables(content, replacements), nil
end

return M
