---@class Vibing.Core.Utils.PromptLoader

local M = {}

---@param str string
---@return string
local function escape_pattern(str)
  return str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
end

---@param template string
---@param replacements table<string, string>
---@return string
local function substitute_variables(template, replacements)
  local result = template
  for key, value in pairs(replacements) do
    local pattern = escape_pattern("{{" .. key .. "}}")
    local escaped_value = value:gsub("%%", "%%%%")
    result = result:gsub(pattern, escaped_value)
  end
  return result
end

---`prompts/` を持つプラグインルートを返す
---
---このモジュール自身の位置から辿る。runtimepath を「`vibing.nvim` という名前のディレクトリ」で
---探す方法も取れるが、それはチェックアウトのディレクトリ名に依存する: git worktree
---（`.vibing/worktrees/<branch>/`）、任意の名前でのclone、プラグインマネージャによっては
---付くサフィックスのいずれでも外れ、`prompts/` が読めずに要約とタイトル生成が丸ごと失敗する。
---モジュールのパスはインストール方法に依らない。
---@return string|nil
local function get_plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    -- <root>/lua/vibing/core/utils/prompt_loader.lua から <root> まで5階層
    local root = vim.fn.fnamemodify(source:sub(2), ":p:h:h:h:h:h")
    if vim.fn.isdirectory(root .. "/prompts") == 1 then
      return root
    end
  end

  -- 素の `require` ではなく文字列から読み込まれた場合（source が "@path" でない）に備えた保険
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    if vim.fn.isdirectory(path .. "/prompts") == 1 and vim.fn.isdirectory(path .. "/lua/vibing") == 1 then
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
