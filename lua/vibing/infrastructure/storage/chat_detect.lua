---チャットファイル自動検知モジュール
---`.md`と`.vibing`の両方の拡張子をサポートし、フロントマターで判定してアタッチする
local M = {}

---アタッチ済みバッファを追跡
---@type table<number, boolean>
local attached_bufs = {}

---バッファにvibing.nvimチャット機能をアタッチ
---@param buf number バッファ番号
local function try_attach(buf)
  -- 既にアタッチ済みならスキップ
  if attached_bufs[buf] then
    return
  end

  -- バッファが有効かチェック
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
  if Frontmatter.is_vibing_chat_buffer(buf) then
    attached_bufs[buf] = true
    vim.schedule(function()
      local view = require("vibing.presentation.chat.view")
      local file_path = vim.api.nvim_buf_get_name(buf)
      if file_path and file_path ~= "" then
        view.attach_to_buffer(buf, file_path)
      end
    end)
  end
end

---チャットファイル検知のautocmdをセットアップ
function M.setup()
  local group = vim.api.nvim_create_augroup("VibingChatDetect", { clear = true })

  -- .md と .vibing の両方を検知
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "BufWinEnter" }, {
    pattern = { "*.md", "*.vibing" },
    group = group,
    callback = function(ev)
      try_attach(ev.buf)
    end,
    desc = "Attach vibing.nvim to chat files with vibing.nvim frontmatter",
  })

  -- バッファ削除時のクリーンアップ
  vim.api.nvim_create_autocmd("BufDelete", {
    pattern = { "*.md", "*.vibing" },
    group = group,
    callback = function(ev)
      attached_bufs[ev.buf] = nil

      -- 実行中のジョブをキャンセル
      local view = require("vibing.presentation.chat.view")
      if view._attached_buffers and view._attached_buffers[ev.buf] then
        local chat_buf = view._attached_buffers[ev.buf]
        -- close()を呼んでジョブキャンセルとタイマー停止
        if chat_buf.close then
          pcall(chat_buf.close, chat_buf)
        end
        view._attached_buffers[ev.buf] = nil
      end
    end,
    desc = "Cleanup vibing.nvim resources on buffer delete",
  })
end

---バッファがアタッチ済みかどうかを確認
---@param buf number バッファ番号
---@return boolean
function M.is_attached(buf)
  return attached_bufs[buf] == true
end

---アタッチ済みバッファをクリア（テスト用）
function M.clear_attached()
  attached_bufs = {}
end

return M
