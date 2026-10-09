---@class Vibing.Utils.FileBuffer
---「このファイルを持っているバッファはどれか」に答える唯一の場所。
---
---**Neovim はバッファ名をシンボリックリンクを解いた形で持つ**（macOS の `/var` は
---`/private/var` になる）。`fnamemodify(path, ":p")` 同士を比べると同じファイルを取り逃がし、
---その先にあるのは「同じ名前のバッファをもう1つ作ろうとして `E95` で落ちる」だった。
---比較するなら両辺を realpath で揃える。
local M = {}

---@param path string?
---@return string 名前の無いバッファを誤って一致させないよう、空文字は空文字のまま返す
function M.canonical(path)
  if not path or path == "" then
    return ""
  end

  local full = vim.fn.fnamemodify(path, ":p")
  return vim.loop.fs_realpath(full) or full
end

---@param path string?
---@return integer? bufnr そのファイルを持つバッファ
function M.find(path)
  local target = M.canonical(path)
  if target == "" then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and M.canonical(vim.api.nvim_buf_get_name(bufnr)) == target then
      return bufnr
    end
  end

  return nil
end

return M
