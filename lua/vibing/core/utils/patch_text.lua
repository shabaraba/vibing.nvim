---@class Vibing.Utils.PatchText
---リクエストpatchから「そのターンが始まる前のファイル内容」を復元する。
---
---`ui/patch_viewer/revert.lua` も `git apply --reverse` を使うが、あちらは実ワーキングツリーを
---書き換える revert 機能そのもの。こちらは **読むだけ** なので、対象ファイルを一時ツリーへ複製
---してからそこに逆適用する。ワーキングツリーにもユーザーのindexにも一切触れない。
---
---patchの逆適用をgitにやらせるのは、コンテキスト不一致の検出まで含めて正しく判定させるため。
---ターン後にユーザーがそのファイルを編集していれば逆適用は失敗し、呼び出し側は「ベースを
---復元できなかった」と分かる。Luaでhunkを自前適用すると、ここが静かにずれる。
local M = {}

local Fs = require("vibing.core.utils.fs")

---バイナリdiffは行として扱えない。`git diff --binary` が出すこのヘッダで判別する
local BINARY_PATCH_PATTERN = "\nGIT binary patch\n"

---@param path string
---@param content string
---@return boolean
local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(content)
  if not content:match("\n$") then
    f:write("\n")
  end
  f:close()
  return true
end

---1ファイル分のdiffを逆適用して、ターン前の内容を行配列で返す
---
---@param base_dir string patch内パスの基準ディレクトリ（`git apply -p1` を回すcwd）
---@param rel_path string patchに現れる通りのパス（base_dir相対）
---@param file_diff string そのファイルのdiffセクション
---@return string[]|nil lines 失敗時nil。**空テーブルは失敗ではなく**「ターン前は存在しなかった」
---@return string|nil err
function M.before_lines(base_dir, rel_path, file_diff)
  if file_diff:find(BINARY_PATCH_PATTERN, 1, true) then
    return nil, "binary diff cannot be shown as text"
  end

  local abs = base_dir .. "/" .. rel_path
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "file not readable: " .. abs
  end

  -- `tempname()` は存在しないユニークなパスを返す。ツリーのルートにも、隣に置くpatchファイルの
  -- 名前にも使う（patchをツリー内に置くと `git apply` の対象に混ざりうる）
  local tmp_root = vim.fn.tempname()
  local patch_path = tmp_root .. ".patch"
  local target = tmp_root .. "/" .. rel_path

  local cleanup = function()
    vim.fn.delete(tmp_root, "rf")
    vim.fn.delete(patch_path)
  end

  -- `Fs.ensure_dir` は失敗時にfalseではなくLuaのerrorを投げる。呼び出し元は誰もpcallしないので、
  -- ここで受け止めないと `gd` が生のトレースバックで落ちる（本来はpatch_viewerへフォールバック）
  local dir_ok, dir_err = pcall(Fs.ensure_dir, vim.fn.fnamemodify(target, ":h"))
  if not dir_ok then
    cleanup()
    return nil, "failed to create temp directory: " .. tostring(dir_err)
  end

  local copied = (vim.uv or vim.loop).fs_copyfile(abs, target)
  if not copied then
    cleanup()
    return nil, "failed to copy " .. abs
  end

  if not write_file(patch_path, file_diff) then
    cleanup()
    return nil, "failed to write temp patch"
  end

  local result = vim
    .system(
      { "git", "apply", "--reverse", "--whitespace=nowarn", patch_path },
      { cwd = tmp_root, text = true }
    )
    :wait()

  if result.code ~= 0 then
    local err = vim.trim(result.stderr or "")
    cleanup()
    return nil, err ~= "" and err or "git apply --reverse failed"
  end

  -- 逆適用でファイルが消えたなら、そのターンで新規作成されたファイル。ターン前の内容は空で、
  -- Before側は空・After側が全行追加として描かれる（それが事実として正しい）
  if vim.fn.filereadable(target) ~= 1 then
    cleanup()
    return {}, nil
  end

  local lines = vim.fn.readfile(target)
  cleanup()
  return lines, nil
end

return M
