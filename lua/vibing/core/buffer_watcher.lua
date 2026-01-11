---Buffer change watcher using nvim_buf_attach
---Provides real-time buffer change detection for multi-agent coordination
local M = {}

---@class BufferWatcherCallback
---@field on_change fun(bufnr: number, changed_tick: number, firstline: number, lastline: number, new_lastline: number, lines: string[]): nil

---@type table<number, {detach: function, callbacks: BufferWatcherCallback[]}>
local watchers = {}

---バッファの変更監視を開始
---@param bufnr number
---@param callback BufferWatcherCallback
---@return boolean success
function M.attach(bufnr, callback)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- 既存の watcher がある場合はコールバックを追加
  if watchers[bufnr] then
    table.insert(watchers[bufnr].callbacks, callback)
    return true
  end

  -- nvim_buf_attach で変更を監視
  local ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, changedtick, firstline, lastline, new_lastline)
      if not watchers[buf] then
        return
      end

      -- 変更された行を取得
      local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)

      -- 全てのコールバックを実行
      for _, cb in ipairs(watchers[buf].callbacks) do
        local ok_cb, err = pcall(cb.on_change, buf, changedtick, firstline, lastline, new_lastline, lines)
        if not ok_cb then
          vim.notify(
            string.format("[vibing] Buffer watcher callback error: %s", err),
            vim.log.levels.ERROR
          )
        end
      end
    end,
    on_detach = function(_, buf)
      -- バッファが削除された場合のクリーンアップ
      watchers[buf] = nil
    end,
  })

  if ok then
    watchers[bufnr] = {
      detach = function()
        -- nvim_buf_attach の detach は自動的に行われるため、
        -- ここでは watchers テーブルからの削除のみ
        watchers[bufnr] = nil
      end,
      callbacks = { callback },
    }
  end

  return ok
end

---バッファの監視を解除
---@param bufnr number
function M.detach(bufnr)
  if watchers[bufnr] and watchers[bufnr].detach then
    watchers[bufnr].detach()
  end
end

---全ての監視を解除
function M.detach_all()
  for bufnr, watcher in pairs(watchers) do
    if watcher.detach then
      watcher.detach()
    end
  end
  watchers = {}
end

---監視中のバッファ一覧を取得
---@return number[]
function M.get_watched_buffers()
  local buffers = {}
  for bufnr, _ in pairs(watchers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(buffers, bufnr)
    end
  end
  return buffers
end

return M
