---@class Vibing.BufferReload
---変更されたファイルのバッファを自動リロードするユーティリティ
local M = {}

---指定されたファイルパスに対応するバッファをリロード
---@param file_paths string[] リロードするファイルパスのリスト
---@return string[] skipped 未保存の変更があってリロードしなかったファイルパス
function M.reload_files(file_paths)
  if not file_paths or #file_paths == 0 then
    return {}
  end

  local skipped = {}
  for _, file_path in ipairs(file_paths) do
    local normalized = vim.fn.fnamemodify(file_path, ":p")

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        local buf_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
        if normalized == buf_name then
          if vim.bo[buf].modified then
            -- バッファに未保存の変更がある場合はスキップ。呼び出し側に伝えて、
            -- 黙ったままディスク側だけ変わった状態（この後の`:w`が上書きしてしまう）を警告させる
            table.insert(skipped, file_path)
          else
            vim.api.nvim_buf_call(buf, function()
              local ok, err = pcall(vim.cmd, "edit!")
              if not ok then
                vim.notify("Failed to reload buffer: " .. tostring(err), vim.log.levels.WARN)
              end
            end)
          end
        end
      end
    end
  end
  return skipped
end

return M
