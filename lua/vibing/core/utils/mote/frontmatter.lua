---@class Vibing.Utils.Mote.Frontmatter
---チャットfrontmatterからmote関連フィールドを解決する
---send_message（送信時のスナップショット対象）とkeymap_handler（gdフォールバックの
---バックエンド選択）の両方から使われるため、解釈ロジックをここに一元化する
local M = {}

---mote追跡ディレクトリ一覧を解決する
---mote_dirs（配列または文字列）を優先し、後方互換としてmote_cwd（文字列）にフォールバック
---@param frontmatter table|nil チャットのfrontmatter
---@return string[]|nil 追跡ディレクトリ一覧（未指定・空の場合nil）
function M.get_dirs(frontmatter)
  if not frontmatter then
    return nil
  end

  local dirs = frontmatter.mote_dirs
  if type(dirs) == "string" then
    dirs = { dirs }
  end
  if (not dirs or #dirs == 0) and type(frontmatter.mote_cwd) == "string" then
    dirs = { frontmatter.mote_cwd }
  end
  if not dirs or #dirs == 0 then
    return nil
  end
  return dirs
end

return M
