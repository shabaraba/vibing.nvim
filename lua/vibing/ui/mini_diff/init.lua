---@class Vibing.UI.MiniDiff
---ターンのpatchを、実ファイルのバッファ上にインライン表示する `gd` のビューア。
---
---フロート内にdiffテキストを描く `patch_viewer` と違い、こちらは **本物のファイルを開いて**
---mini.diff の参照テキストにターン前の内容を差す。結果として、そのまま編集でき、`gH` が
---hunk単位のrevertになる（mini.diffのresetは「バッファのその範囲を参照テキストで置き換える」
---と定義されていて、sourceに依存しない）。
---
---mini.diffは任意依存。無ければ `gd` は `patch_viewer` にフォールバックする。
---張り付けは `ref_store.lua`、開き先のウィンドウは `ui/code_window.lua`。
local M = {}

local parser = require("vibing.ui.patch_viewer.parser")
local PatchText = require("vibing.core.utils.patch_text")
local RefStore = require("vibing.ui.mini_diff.ref_store")
local CodeWindow = require("vibing.ui.code_window")

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

---参照テキストを指定して、ファイルのバッファ上にインライン表示する
---@param file_path string 対象ファイル
---@param before string[] 参照テキスト。空テーブルは「その時点では存在しなかった」
---@return boolean shown falseなら呼び出し側がフォールバックする
function M.show_ref(file_path, before)
  local diff = mini()
  if not diff then
    return false
  end

  local buf = CodeWindow.open_file(file_path)
  if not buf then
    return false
  end

  return RefStore.attach(diff, buf, before)
end

---ターンのpatchを対象ファイルのバッファ上にインライン表示する
---@param base_dir string patch内パスの基準ディレクトリ
---@param patch_content string
---@param target_file string カーソル下のファイルパス
---@return boolean shown 表示できたか。falseなら呼び出し側がフォールバックする
function M.show(base_dir, patch_content, target_file)
  if not M.is_available() then
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

  return M.show_ref(base_dir .. "/" .. rel_path, before)
end

---1バッファの参照テキストを外す
---@param buf number
function M.clear(buf)
  RefStore.remove(buf)
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
  local buffers = RefStore.buffers()
  for _, buf in ipairs(buffers) do
    M.clear(buf)
  end
  return #buffers
end

---テスト用
M._attach = RefStore.attach
M._marked = RefStore.buffers
M._resolve_rel_path = resolve_rel_path

return M
