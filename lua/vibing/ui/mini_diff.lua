---@class Vibing.UI.MiniDiff
---ターンのpatchを、実ファイルのバッファ上にインライン表示する `gd` のビューア。
---
---フロート内にdiffテキストを描く `patch_viewer` と違い、こちらは **本物のファイルを開いて**
---mini.diff の参照テキストにターン前の内容を差す。結果として、そのまま編集でき、`gH` が
---hunk単位のrevertになる（mini.diffのresetは「バッファのその範囲を参照テキストで置き換える」
---と定義されていて、sourceに依存しない）。
---
---mini.diffは任意依存。無ければ `gd` は `patch_viewer` にフォールバックする。
local M = {}

local parser = require("vibing.ui.patch_viewer.parser")
local PatchText = require("vibing.core.utils.patch_text")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---参照テキストを差したバッファ。`:VibingDiffClear` が戻す対象
---@type table<number, boolean>
local marked = {}

---@return table|nil
local function mini()
  local ok, m = pcall(require, "mini.diff")
  if not ok or type(m) ~= "table" then
    return nil
  end
  return m
end

---@return boolean
function M.is_available()
  return mini() ~= nil
end

---patchに現れる **生のパス** を、カーソル下のファイルパスと突き合わせて解決する
---
---`parser.extract_files` はNeovimのcwd相対に正規化してしまうが、ここで欲しいのは一時ツリーに
---ファイルを置く位置＝patch内の表記そのもの。base_dirはcwdと一致しないことがある（worktree、
---`working_dir` 指定）ので、正規化済みの値では復元できない。
---@param patch_content string
---@param target string
---@return string|nil
local function resolve_rel_path(patch_content, target)
  local abs_target = vim.fn.fnamemodify(target, ":p")
  for line in patch_content:gmatch("[^\r\n]+") do
    local raw = line:match("^diff %-%-git a/(.+) b/")
    if raw then
      local is_same = raw == target
        or vim.fn.fnamemodify(raw, ":p") == abs_target
        -- パス境界での後方一致。base_dir相対の表記が絶対パスの末尾に現れる普通のケース
        or abs_target:sub(-(#raw + 1)) == "/" .. raw
      if is_same then
        return raw
      end
    end
  end
  return nil
end

---ファイルを開いてよい通常ウィンドウを選ぶ。無ければ縦分割で作る
---
---`gd` はチャットウィンドウから押されるので、そこに `:edit` するとチャットが消える。
---@return number winnr
local function code_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      -- フロートは閉じられる前提の一時ウィンドウなので、そこにファイルを開くと差分ごと消える。
      -- `buftype ~= ""` はターミナル・quickfix・help・ファイラ（oil等）で、どれも `:edit` で
      -- 乗っ取ってよいウィンドウではない。この2つを外すと、残るのは普通のファイル用ウィンドウ
      local is_float = vim.api.nvim_win_get_config(win).relative ~= ""
      local is_normal = vim.bo[buf].buftype == ""
      if not is_float and is_normal and not Frontmatter.is_vibing_chat_buffer(buf) then
        return win
      end
    end
  end

  vim.cmd("vsplit")
  return vim.api.nvim_get_current_win()
end

---ターンのpatchを対象ファイルのバッファ上にインライン表示する
---@param base_dir string patch内パスの基準ディレクトリ
---@param patch_content string
---@param target_file string カーソル下のファイルパス
---@return boolean shown 表示できたか。falseなら呼び出し側がフォールバックする
function M.show(base_dir, patch_content, target_file)
  local diff = mini()
  if not diff then
    return false
  end

  local rel_path = resolve_rel_path(patch_content, target_file)
  if not rel_path then
    return false
  end

  local file_diff = parser.extract_file_diff(patch_content, rel_path)
  if not file_diff then
    return false
  end

  local before, err = PatchText.before_lines(base_dir, rel_path, file_diff)
  if not before then
    vim.notify(
      string.format("[vibing] Inline diff unavailable for %s: %s", rel_path, err or "unknown error"),
      vim.log.levels.WARN
    )
    return false
  end

  local win = code_window()
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(base_dir .. "/" .. rel_path))
  local buf = vim.api.nvim_get_current_buf()

  M._attach(diff, buf, before)
  return true
end

---@param diff table mini.diffモジュール
---@param buf number
---@param before string[]
function M._attach(diff, buf, before)
  -- 一度disableしてから設定する。sourceのattachは **enable時にしか起きない** ので、既に
  -- enable済みのバッファに `minidiff_config` を書いても効かない。`set_ref_text` は未enableの
  -- バッファをenableするため、この順序なら必ず `none` のsourceで張り直される。
  --
  -- これを怠ると、既定のgit sourceがattachしたままになり、次に `.git/index` が動いた時点で
  -- ターンの参照テキストが黙ってgit indexの内容に置き換わる。
  pcall(diff.disable, buf)

  local buf_config = vim.b[buf].minidiff_config or {}
  buf_config.source = diff.gen_source.none()
  vim.b[buf].minidiff_config = buf_config

  diff.set_ref_text(buf, before)
  marked[buf] = true

  -- overlayは削除行を仮想テキストで見せる。ターンで消えた行はファイル上に残っていないので、
  -- これが無いと「何が消えたか」が分からない
  local data = diff.get_buf_data(buf)
  if data and not data.overlay then
    pcall(diff.toggle_overlay, buf)
  end
end

---1バッファの参照テキストを外す
---@param buf number
function M.clear(buf)
  marked[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local diff = mini()
  if diff then
    pcall(diff.disable, buf)
  end
  vim.b[buf].minidiff_config = nil
end

---`gd` が差したものをすべて外す
---@return number cleared 外したバッファ数
function M.clear_all()
  local buffers = vim.tbl_keys(marked)
  for _, buf in ipairs(buffers) do
    M.clear(buf)
  end
  return #buffers
end

---テスト用
function M._marked()
  return vim.tbl_keys(marked)
end

M._resolve_rel_path = resolve_rel_path

return M
