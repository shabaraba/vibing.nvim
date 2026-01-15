---@class Vibing.Infrastructure.Squad.Registry
---現在アクティブなSquadのインメモリ管理
---SessionManagerパターンを参考にした軽量Registry
local M = {}

---現在使用中の分隊名 → bufnr のマッピング
---@type table<string, number>
M._active_squads = {}

---分隊名を登録
---@param squad_name string 分隊名
---@param bufnr number バッファ番号
function M.register(squad_name, bufnr)
  M._active_squads[squad_name] = bufnr
end

---バッファの分隊名を解除
---@param bufnr number バッファ番号
function M.unregister(bufnr)
  for name, buf in pairs(M._active_squads) do
    if buf == bufnr then
      M._active_squads[name] = nil
      return
    end
  end
end

---分隊名が使用可能かチェック（衝突検出）
---@param squad_name string 分隊名
---@return boolean available 使用可能な場合true
function M.is_available(squad_name)
  local bufnr = M._active_squads[squad_name]

  -- 登録されていない場合は使用可能
  if not bufnr then
    return true
  end

  -- バッファが無効化されている場合は自動クリーンアップ
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M._active_squads[squad_name] = nil
    return true
  end

  return false
end

---現在アクティブな分隊名リストを取得
---@return table<string, number> { [squad_name] = bufnr }
function M.get_all_active()
  -- 無効なバッファを自動クリーンアップしつつコピーを返す
  local active = {}

  for name, bufnr in pairs(M._active_squads) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      active[name] = bufnr
    else
      -- 無効バッファはクリーンアップ
      M._active_squads[name] = nil
    end
  end

  return active
end

---全ての登録を削除（主にテスト用）
function M.clear_all()
  M._active_squads = {}
end

---無効なバッファの登録を一括クリーンアップ
function M.cleanup_stale()
  for name, bufnr in pairs(M._active_squads) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      M._active_squads[name] = nil
    end
  end
end

---分隊名からバッファ番号を取得
---@param squad_name string 分隊名
---@return number? bufnr バッファ番号（見つからない場合はnil）
function M.find_buffer(squad_name)
  local bufnr = M._active_squads[squad_name]
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  -- 無効バッファはクリーンアップ
  if bufnr then
    M._active_squads[squad_name] = nil
  end
  return nil
end

return M
