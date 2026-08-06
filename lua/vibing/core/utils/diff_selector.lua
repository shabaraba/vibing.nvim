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

---ファイルのgit diffを表示（HEADとの比較）
---@param file_path string ファイルパス（絶対パス）
local function show_git_diff(file_path)
  local abs = vim.fn.fnamemodify(file_path, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")

  local result = vim.system({ "git", "diff", "HEAD", "--", abs }, { cwd = dir, text = true }):wait()
  if result.code ~= 0 then
    -- HEADが無い場合（初回コミット前など）はworking treeのdiffにフォールバック
    result = vim.system({ "git", "diff", "--", abs }, { cwd = dir, text = true }):wait()
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

---ファイルのdiffを表示
---patchファイルが見つからない場合のフォールバック。diff.tool = "mote" のときだけmoteを使い、
---それ以外（"auto" / "git"）はgit diffで表示する。
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（未使用、互換性のため保持）
---@param cwd? string 作業ディレクトリ（frontmatterのworking_dirから算出、worktree判定用）
function M.show_diff(file_path, session_id, cwd)
  local config = require("vibing.config").get()
  local tool = config.diff and config.diff.tool or "auto"

  if tool ~= "mote" then
    show_git_diff(file_path)
    return
  end

  local MoteDiff = require("vibing.core.utils.mote_diff")
  local mote_config = vim.deepcopy(config.diff.mote)

  -- Normalize cwd to absolute path
  local abs_cwd = cwd and vim.fn.fnamemodify(cwd, ":p") or nil

  -- mote v0.2.4: --project/--context APIを使用
  mote_config.project = mote_config.project or MoteDiff.get_project_name(abs_cwd)
  local context_prefix = mote_config.context_prefix or "vibing"
  mote_config.context = MoteDiff.build_context_name(context_prefix, abs_cwd)

  if abs_cwd then
    mote_config.cwd = abs_cwd
  end

  MoteDiff.show_diff(file_path, mote_config)
end

return M
