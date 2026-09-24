---@class Vibing.Utils.MediaPath
---画像・動画パスの判定と解決。`gx` が既定のアプリケーションへ渡す対象を決める。
local M = {}

-- Neovim のバッファで開いても読めず、OS の既定アプリで開くのが正しい拡張子だけを挙げる。
-- SVG はテキストとしても読めるが、チャットに貼られる場合は表示が目的なので含める。
local MEDIA_EXTENSIONS = {
  -- 画像
  avif = true,
  bmp = true,
  gif = true,
  heic = true,
  heif = true,
  ico = true,
  jpeg = true,
  jpg = true,
  png = true,
  svg = true,
  tif = true,
  tiff = true,
  webp = true,
  -- 動画
  avi = true,
  flv = true,
  m4v = true,
  mkv = true,
  mov = true,
  mp4 = true,
  mpeg = true,
  mpg = true,
  webm = true,
  wmv = true,
}

---拡張子が画像・動画かを判定する（大文字小文字は区別しない）
---@param path string
---@return boolean
function M.is_media(path)
  local ext = path:match("%.(%w+)$")
  return ext ~= nil and MEDIA_EXTENSIONS[ext:lower()] == true
end

---パスを実在する絶対パスへ解決する。
---相対パスは Neovim の cwd と `cwd` 引数（チャットの working_dir）の両方で試す。
---worktree に紐づいたチャットでは前者が一致しないため。
---@param path string
---@param cwd string? 相対パスの解決基準
---@return string? 実在する絶対パス（見つからなければ nil）
function M.resolve(path, cwd)
  local expanded = vim.fn.expand(path)
  if expanded == "" then
    return nil
  end
  if vim.fn.filereadable(expanded) == 1 then
    return vim.fn.fnamemodify(expanded, ":p")
  end
  if cwd and expanded:sub(1, 1) ~= "/" then
    local absolute = vim.fn.fnamemodify(cwd .. "/" .. expanded, ":p")
    if vim.fn.filereadable(absolute) == 1 then
      return absolute
    end
  end
  return nil
end

---カーソル下の `<cfile>` が実在する画像・動画なら、その絶対パスを返す。
---`<cfile>` は `isfname` に従うので、`` `path.png` ``・`![alt](path.png)`・
---`### Modified Files` のパス行のいずれでもパス本体だけが取れる。
---@param cwd string? 相対パスの解決基準
---@return string? 絶対パス（メディアでない、または存在しない場合は nil）
function M.find_under_cursor(cwd)
  local cfile = vim.fn.expand("<cfile>")
  if cfile == "" or not M.is_media(cfile) then
    return nil
  end
  return M.resolve(cfile, cwd)
end

return M
