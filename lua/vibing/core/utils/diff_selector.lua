---@class Vibing.Utils.DiffSelector
---patchファイルが見つからない場合のdiff表示フォールバックを管理
local M = {}

---diff内容をスクラッチバッファに表示
---@param output string diff出力
local function show_diff_buffer(output)
  local Factory = require("vibing.infrastructure.ui.factory")
  local buf = Factory.create_buffer({
    buftype = "nofile",
    bufhidden = "wipe",
    filetype = "diff",
    modifiable = true,
  })

  local lines = vim.split(output, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)

  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, {
    buffer = buf,
    noremap = true,
    silent = true,
  })
end

---ファイルのgit diffを表示
---追跡済みならHEAD（無ければindex）との比較、未追跡・リポジトリ外なら
---git diff --no-index /dev/null でファイル全体を新規追加として表示する
---@param file_path string ファイルパス（絶対パス）
local function show_git_diff(file_path)
  local abs = vim.fn.fnamemodify(file_path, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")

  local tracked = vim.system({ "git", "ls-files", "--error-unmatch", "--", abs }, { cwd = dir, text = true }):wait()

  local result
  if tracked.code == 0 then
    result = vim.system({ "git", "diff", "HEAD", "--", abs }, { cwd = dir, text = true }):wait()
    if result.code ~= 0 then
      -- HEADが無い場合（初回コミット前）はindexとの比較にフォールバック
      result = vim.system({ "git", "diff", "--cached", "--", abs }, { cwd = dir, text = true }):wait()
    end
  else
    -- 未追跡ファイル・リポジトリ外: /dev/nullと比較して全体を新規として表示
    -- （--no-indexは差分ありで終了コード1を返すので正常扱い）
    result = vim.system({ "git", "diff", "--no-index", "--", "/dev/null", abs }, { cwd = dir, text = true }):wait()
    if result.code == 1 then
      result.code = 0
    end
  end

  if result.code ~= 0 then
    vim.notify("[vibing] git diff failed: " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  local output = result.stdout or ""
  if output == "" or output:match("^%s*$") then
    vim.notify("[vibing] No changes to show", vim.log.levels.INFO)
    return
  end

  show_diff_buffer(output)
end

---file_pathを含むmote_dirを探す（ネストしたmote_dirsは最長一致=最も深いディレクトリを優先）
---ファイルパス（gdの対象）を想定しており、mote_dirそのものを指すパスは
---配下のファイルではないため意図的にマッチさせない
---@param file_path string 絶対パス
---@param mote_dirs string[]|nil チャットのmote_dirs frontmatter
---@return string|nil マッチした追跡ディレクトリ（絶対パス）
local function find_mote_dir(file_path, mote_dirs)
  local abs = vim.fn.fnamemodify(file_path, ":p")
  local best = nil
  for _, dir in ipairs(mote_dirs or {}) do
    local base = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
    if abs:sub(1, #base + 1) == base .. "/" and (not best or #base > #best) then
      best = base
    end
  end
  return best
end

-- テスト用エクスポート
M._find_mote_dir = find_mote_dir
M._show_git_diff = function(file_path)
  return show_git_diff(file_path)
end

---ファイルのdiffを表示
---patchファイルが見つからない場合のフォールバック。送信時のバックエンド選択と同じ規則で、
---diff.tool = "mote" またはチャットのmote_dirsが対象ファイルをカバーする場合はmote、
---それ以外（"auto" / "git"）はgit diffで表示する。
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（未使用、互換性のため保持）
---@param cwd? string 作業ディレクトリ（frontmatterのworking_dirから算出、worktree判定用）
---@param mote_dirs? string[] チャットのmote_dirs frontmatter（VibingMoteDirで指定）
function M.show_diff(file_path, session_id, cwd, mote_dirs)
  local config = require("vibing.config").get()
  local tool = config.diff and config.diff.tool or "auto"

  local matched_mote_dir = find_mote_dir(file_path, mote_dirs)
  if tool ~= "mote" and not matched_mote_dir then
    show_git_diff(file_path)
    return
  end

  local MoteDiff = require("vibing.core.utils.mote_diff")
  local mote_config = vim.deepcopy(config.diff.mote)
  local context_prefix = mote_config.context_prefix or "vibing"

  if matched_mote_dir then
    -- VibingMoteDirで指定されたディレクトリ配下: 送信時（_create_session_mote_configs）は
    -- diff.toolの値に関係なくmote_dirs優先でディレクトリ単位コンテキストにスナップショットを
    -- 書くため、表示側も同じコンテキストを使う（tool = "mote" 併用時も含む）
    mote_config.project = mote_config.project or MoteDiff.get_project_name(matched_mote_dir)
    mote_config.context = MoteDiff.build_context_name_from_path(context_prefix, matched_mote_dir)
    mote_config.cwd = matched_mote_dir
  else
    -- Normalize cwd to absolute path
    local abs_cwd = cwd and vim.fn.fnamemodify(cwd, ":p") or nil

    -- mote v0.2.4: --project/--context APIを使用
    mote_config.project = mote_config.project or MoteDiff.get_project_name(abs_cwd)
    mote_config.context = MoteDiff.build_context_name(context_prefix, abs_cwd)

    if abs_cwd then
      mote_config.cwd = abs_cwd
    end
  end

  MoteDiff.show_diff(file_path, mote_config)
end

return M
