---@class Vibing.Utils.PathResolve
---チャットに書かれた相対パスを、実在する絶対パスへ解決する唯一の場所。
---`gx` のメディアパスと `gf` / `gd` のリンク先が同じ答えを出すための共有基盤。
local M = {}

---`~` と `$VAR` だけを展開する。
---`vim.fn.expand` をそのまま通すと、パスに含まれる `%` や `#` がカレント／オルタネート
---バッファ名に化ける（`notes#1.png` が別のファイルとして解決される）
---@param path string
---@return string
local function expand_prefix(path)
  local head = path:sub(1, 1)
  if head == "~" or head == "$" then
    return vim.fn.expand(path)
  end
  return path
end

---パスを実在するファイルの絶対パスへ解決する。
---相対パスはチャットの working_dir を先に、次に Neovim の cwd を試す — worktree に
---紐づいたチャットでは後者が一致しない。
---@param path string
---@param cwd string? 相対パスの解決基準（チャットの working_dir）
---@return string? 実在する絶対パス（見つからなければ nil）
function M.existing_file(path, cwd)
  local expanded = expand_prefix(path)
  if expanded == "" then
    return nil
  end

  if expanded:sub(1, 1) == "/" then
    local absolute = vim.fn.fnamemodify(expanded, ":p")
    return vim.fn.filereadable(absolute) == 1 and absolute or nil
  end

  local tried = {}
  for _, base in ipairs({ cwd, vim.fn.getcwd() }) do
    if base and not tried[base] then
      tried[base] = true
      local absolute = vim.fn.fnamemodify(base .. "/" .. expanded, ":p")
      if vim.fn.filereadable(absolute) == 1 then
        return absolute
      end
    end
  end
  return nil
end

return M
