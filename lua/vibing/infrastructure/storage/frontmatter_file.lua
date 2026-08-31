---@class Vibing.Infrastructure.Storage.FrontmatterFile
---チャットファイルのfrontmatterを、そのファイルが**開かれている場合はバッファ経由で**更新する。
---
---リンクのリネーム同期はディスクを直接書いていたが、同期対象は原理的に開かれていることが多い
---（オーケストレーションのリンクはbufnr起点で張られるので、相手は常にロード済み）。開いている
---バッファを迂回して書くと2通りに壊れる:
---
---  1. そのバッファの次の保存が、書いた内容をそのまま巻き戻す（`write!`はVimの
---     「読み込み後にファイルが変わった」ガードを黙って踏み越える）
---  2. ガードが効く保存だと `Do you really want to write to it (y/n)?` のプロンプトが出る。
---     チャットの保存は `vim.schedule` の中から走るので、そこでNeovimが止まる
---
---ロードされていなければ従来通りディスクに書く。
local M = {}

local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local PathSanitizer = require("vibing.domain.security.path_sanitizer")

---@param file_path string
---@return number? bufnr
local function loaded_buffer(file_path)
  -- 比較は両側ともシンボリックリンクを解決した形で行う。`nvim_buf_get_name` は解決済みの
  -- パスを返すので（macOSでは `/var/...` が `/private/var/...` になる）、`:p` だけでは
  -- 同じファイルが一致しない。`PathSanitizer.normalize` が expand→`:p`→resolve をまとめている
  local target = PathSanitizer.normalize(file_path)
  if not target then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and PathSanitizer.normalize(name) == target then
        return bufnr
      end
    end
  end

  return nil
end

---frontmatterブロックだけを差し替える。本文には触れない
---（ストリーミング中のバッファを丸ごと書き換えると応答を壊す）
---@param bufnr number
---@param updates table
---@return boolean success
---@return string? error
local function update_buffer(bufnr, updates)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if lines[1] ~= "---" then
    return false, "Buffer has no frontmatter"
  end

  local close = nil
  for i = 2, #lines do
    if lines[i] == "---" then
      close = i
      break
    end
  end
  if not close then
    return false, "Buffer frontmatter is not terminated"
  end

  local block = table.concat(vim.list_slice(lines, 1, close), "\n")
  local updated = Frontmatter.update(block, updates)
  vim.api.nvim_buf_set_lines(bufnr, 0, close, false, vim.split(updated, "\n", { plain = true }))

  -- ここで保存しないと、同期したと報告した内容がディスクに無いままになる。
  -- バッファ側を真として書いているので、`write!` でガードを踏み越えても失うものはない
  if not require("vibing.presentation.chat.modules.file_manager").save_buffer(bufnr) then
    return false, "Updated the buffer but could not save it"
  end

  return true, nil
end

---@param file_path string
---@param updates table
---@return boolean success
---@return string? error
local function update_file(file_path, updates)
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return false, string.format("Failed to read file: %s", lines or "unknown")
  end

  local updated = Frontmatter.update(table.concat(lines, "\n"), updates)
  if vim.fn.writefile(vim.split(updated, "\n", { plain = true }), file_path) ~= 0 then
    return false, string.format("Failed to write file: %s", vim.v.errmsg or "unknown")
  end

  return true, nil
end

---frontmatterのキーを更新する。開かれていればバッファ経由、なければディスクへ
---@param file_path string
---@param updates table
---@return boolean success
---@return string? error
function M.update(file_path, updates)
  local bufnr = loaded_buffer(file_path)
  if bufnr then
    return update_buffer(bufnr, updates)
  end
  return update_file(file_path, updates)
end

return M
