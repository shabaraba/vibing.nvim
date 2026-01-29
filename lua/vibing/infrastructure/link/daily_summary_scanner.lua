---@class Vibing.Infrastructure.Link.DailySummaryScanner : Vibing.Infrastructure.Link.Scanner
local DailySummaryScanner = {}
DailySummaryScanner.__index = DailySummaryScanner

local Scanner = require("vibing.infrastructure.link.scanner")
setmetatable(DailySummaryScanner, { __index = Scanner })

---@return Vibing.Infrastructure.Link.DailySummaryScanner
function DailySummaryScanner.new()
  return setmetatable({}, DailySummaryScanner)
end

---@param base_dir string
---@return string
local function get_daily_summary_dir(base_dir)
  -- base_dirがすでにdaily summaryディレクトリを指している場合はそのまま返す
  -- （例: ObsidianVaultのように直接daily summaryディレクトリが設定されている場合）
  if base_dir:match("/daily/?$") or base_dir:match("/Daily/?$") then
    return base_dir:match("/$") and base_dir or (base_dir .. "/")
  end

  -- chat保存ディレクトリから派生する場合
  if base_dir:match("/chat/$") then
    return base_dir:gsub("/chat/$", "/daily/")
  end

  return base_dir .. "daily/"
end

---@param base_dir string
---@return string[]
function DailySummaryScanner:find_target_files(base_dir)
  local daily_dir = get_daily_summary_dir(base_dir)

  if vim.fn.isdirectory(daily_dir) == 0 then
    return {}
  end

  return vim.fn.glob(daily_dir .. "*.md", false, true)
end

---@param file_path string
---@param target_path string
---@return boolean
function DailySummaryScanner:contains_link(file_path, target_path)
  local ok, content = pcall(vim.fn.readfile, file_path)
  if not ok or not content or #content == 0 then
    return false
  end

  local target_tilde = vim.fn.fnamemodify(target_path, ":p:~")

  for _, line in ipairs(content) do
    if line:find(target_tilde, 1, true) then
      return true
    end
  end

  return false
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function DailySummaryScanner:update_link(file_path, old_path, new_path)
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return false, string.format("Failed to read file: %s", lines or "unknown")
  end

  local old_tilde = vim.fn.fnamemodify(old_path, ":p:~")
  local new_tilde = vim.fn.fnamemodify(new_path, ":p:~")

  local updated = false
  for i, line in ipairs(lines) do
    if line:find(old_tilde, 1, true) then
      lines[i] = line:gsub(vim.pesc(old_tilde), new_tilde)
      updated = true
    end
  end

  if not updated then
    return true, nil
  end

  local result = vim.fn.writefile(lines, file_path)
  if result ~= 0 then
    return false, string.format("Failed to write file: %s", vim.v.errmsg or "unknown")
  end

  return true, nil
end

return DailySummaryScanner
