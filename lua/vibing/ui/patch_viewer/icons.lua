---@class Vibing.PatchViewer.Icons
---ファイルアイコン。mini.icons か nvim-web-devicons が入っていれば借りる。
---どちらも無いのは普通のことなので、その時は素直にアイコン無しで描く。
local M = {}

---@param path string
---@return string? icon
---@return string? hl
function M.get(path)
  local name = vim.fn.fnamemodify(path, ":t")

  local ok, mini = pcall(require, "mini.icons")
  if ok then
    -- setup() 前の MiniIcons.get は落ちる。入っているだけで使えるとは限らない
    local got, icon, hl = pcall(mini.get, "file", name)
    if got and icon then
      return icon, hl
    end
  end

  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    local icon, hl = devicons.get_icon(name, vim.fn.fnamemodify(path, ":e"), { default = true })
    if icon then
      return icon, hl
    end
  end

  return nil, nil
end

return M
