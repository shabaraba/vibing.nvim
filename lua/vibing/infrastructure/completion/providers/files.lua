---@class Vibing.FilesProvider
---Provides file path candidates using git ls-files
---@module "vibing.infrastructure.completion.providers.files"
local M = {}

---@type Vibing.CompletionItem[]?
local _cache = nil
local _cache_time = 0
local CACHE_TTL_MS = 5000

---Build completion items from file list
---@param files string[]
---@return Vibing.CompletionItem[]
local function build_items(files)
  local items = {}
  for _, file in ipairs(files) do
    table.insert(items, {
      word = file,
      label = file,
      kind = "File",
      source = "project",
      filterText = file,
    })
  end
  return items
end

---Update cache with new items
---@param items Vibing.CompletionItem[]
local function update_cache(items)
  _cache = items
  _cache_time = vim.loop.now()
end

---Check if cache is valid
---@return boolean
local function is_cache_valid()
  if not _cache then
    return false
  end
  local now = vim.loop.now()
  return (now - _cache_time) < CACHE_TTL_MS
end

---Get all file candidates asynchronously (for nvim-cmp)
---@param callback fun(items: Vibing.CompletionItem[])
function M.get_all_async(callback)
  if is_cache_valid() then
    callback(_cache)
    return
  end

  local ok, _ = pcall(vim.system, { "git", "ls-files" }, { text = true, cwd = vim.fn.getcwd() }, vim.schedule_wrap(function(result)
    local success, items = pcall(function()
      if result.code ~= 0 then
        return {}
      end
      local files = vim.split(result.stdout or "", "\n", { trimempty = true })
      return build_items(files)
    end)

    local final_items = success and items or {}
    update_cache(final_items)
    callback(final_items)
  end))

  if not ok then
    callback({})
  end
end

---Get all file candidates synchronously (for omnifunc fallback)
---@return Vibing.CompletionItem[]
function M.get_all_sync()
  if is_cache_valid() then
    return _cache
  end

  local ok, result = pcall(vim.fn.systemlist, "git ls-files")
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end

  local items = build_items(result or {})
  update_cache(items)
  return items
end

---Clear cache
function M.clear_cache()
  _cache = nil
  _cache_time = 0
end

return M
