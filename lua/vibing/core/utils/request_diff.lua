---@class Vibing.Utils.RequestDiff
---リクエスト単位の軽量diff機構（`git_snapshot.lua` のフォールバック）
---
---PreToolUseフックの時点（ツール実行前）で、Write/Edit系ツールが対象とするファイルの
---「変更前」内容だけをtmpに退避し、レスポンス完了時に退避内容と現在の内容を
---vim.diff()（組み込みxdiff）で比較してgit形式のpatchを生成する。
---
---**主経路は `git_snapshot.lua`。** こちらが残っているのは、あちらが成立しない2つの場合の
---ためだけ:
---  1. `working_dir` がgitリポジトリでない（スナップショットを取る先が無い）
---  2. 同じworktreeで別のチャットが同時に走っている（ツリー差分は他方の変更も拾ってしまう）
---
---ツールの引数に現れたファイルしか見ないので、**Bash由来の変更は捕捉できない**。それが
---git_snapshotを主経路にした理由でもある。コストは「そのリクエストで実際に触ったファイル数」
---にのみ比例し、バックアップはhandle_id（リクエスト）単位なので、並行するチャットバッファ間で
---差分が混ざることはない。
local Fs = require("vibing.core.utils.fs")

local M = {}

local uv = vim.uv or vim.loop

---@class Vibing.RequestDiff.Entry
---@field existed boolean 退避時点でファイルが存在したか
---@field backup_path string|nil 退避先パス（existed=falseの場合nil）

---@class Vibing.RequestDiff.Session
---@field dir string|nil バックアップディレクトリ
---@field count number 退避ファイルの連番
---@field created number セッション作成時刻（os.time）
---@field files table<string, Vibing.RequestDiff.Entry> 絶対パス→退避情報
---@field order string[] 退避順の絶対パスリスト

---handle_idごとの退避状態
---@type table<string, Vibing.RequestDiff.Session>
local sessions = {}

---ツール名→tool_input内のファイルパスキー
local TOOL_PATH_KEYS = {
  Write = "file_path",
  Edit = "file_path",
  MultiEdit = "file_path",
  NotebookEdit = "notebook_path",
}

---キャンセル等でclearされなかったセッションの掃除用TTL（秒）
local SESSION_TTL_SEC = 3600

---@param path string
---@return string|nil
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

---@param abs string 絶対パス
---@param base string|nil 基準ディレクトリ（絶対パス）
---@return string rel base配下なら相対パス、そうでなければ絶対パスのまま
---@return boolean under_base base配下だったか
local function to_rel(abs, base)
  if base and base ~= "" then
    local prefix = base:sub(-1) == "/" and base or (base .. "/")
    if abs:sub(1, #prefix) == prefix then
      return abs:sub(#prefix + 1), true
    end
  end
  return abs, false
end

---TTL超過した放置セッション（キャンセルされたリクエスト等）を破棄
local function sweep_stale()
  local now = os.time()
  for handle_id, s in pairs(sessions) do
    if now - s.created > SESSION_TTL_SEC then
      if s.dir then
        vim.fn.delete(s.dir, "rf")
      end
      sessions[handle_id] = nil
    end
  end
end

---ツール実行前にファイル内容を退避する（PreToolUseフックの許可パスから呼ぶ）
---同一リクエスト内で同じファイルが複数回編集されても、最初の退避
---（=リクエスト開始時点の状態）を保持する。
---@param handle_id string|nil リクエストのハンドルID
---@param tool_name string ツール名
---@param tool_input table ツール入力
function M.capture(handle_id, tool_name, tool_input)
  if not handle_id or handle_id == "" then
    return
  end
  local path_key = TOOL_PATH_KEYS[tool_name]
  if not path_key or type(tool_input) ~= "table" then
    return
  end
  local path = tool_input[path_key]
  if type(path) ~= "string" or path == "" then
    return
  end

  sweep_stale()

  local abs = vim.fn.fnamemodify(path, ":p")
  local s = sessions[handle_id]
  if not s then
    s = { dir = nil, count = 0, created = os.time(), files = {}, order = {} }
    sessions[handle_id] = s
  end
  if s.files[abs] then
    return
  end

  local stat = uv.fs_stat(abs)
  if not stat then
    s.files[abs] = { existed = false }
    table.insert(s.order, abs)
    return
  end
  if stat.type ~= "file" then
    return
  end

  if not s.dir then
    s.dir = vim.fn.tempname() .. ".vibing-reqdiff"
    Fs.ensure_dir(s.dir)
  end
  s.count = s.count + 1
  local backup_path = string.format("%s/%d", s.dir, s.count)
  local ok = uv.fs_copyfile(abs, backup_path)
  if not ok then
    -- 退避に失敗したファイルはdiff対象から外す（一覧には extra_paths 経由で載る）
    return
  end
  s.files[abs] = { existed = true, backup_path = backup_path }
  table.insert(s.order, abs)
end

---git diff --no-index で2ファイル間のhunk部分（@@以降）を取得
---vim.diff()と違い「\ No newline at end of file」マーカーを正しく出力するため、
---末尾改行がないファイルはこちらで比較する（git apply --reverse での復元が保証される）
---@param old_path string 比較元（存在しない側は "/dev/null"）
---@param new_path string 比較先（存在しない側は "/dev/null"）
---@return string|nil hunks（差分がない/取得できない場合nil）
local function git_no_index_hunks(old_path, new_path)
  local result = vim
    .system({ "git", "diff", "--no-index", "--", old_path, new_path }, { text = true })
    :wait()
  -- --no-index は差分ありで終了コード1を返す
  if result.code ~= 0 and result.code ~= 1 then
    return nil
  end
  local output = result.stdout or ""
  local hunk_start = output:find("\n@@", 1, true)
  if not hunk_start then
    return nil
  end
  return output:sub(hunk_start + 1)
end

---1ファイル分のdiffセクションを生成
---@param rel string 相対パス
---@param entry Vibing.RequestDiff.Entry 退避情報
---@param abs string 絶対パス（現在のファイル）
---@param before string|nil 変更前内容（nil=ファイルが存在しなかった）
---@param after string|nil 変更後内容（nil=ファイルが削除された）
---@return string|nil diffセクション（変更がない/patch化できない場合nil）
local function build_file_section(rel, entry, abs, before, after)
  local before_text = before or ""
  local after_text = after or ""
  if before_text == after_text then
    return nil
  end

  -- バイナリはgit applyで復元できるpatchにならないため、一覧のみでdiffセクションは作らない
  if before_text:find("\0", 1, true) or after_text:find("\0", 1, true) then
    return nil
  end

  local hunks
  local missing_trailing_newline = (before and before ~= "" and not before:match("\n$"))
    or (after and after ~= "" and not after:match("\n$"))
  if missing_trailing_newline then
    local old_path = (before and entry.backup_path) or "/dev/null"
    local new_path = after and abs or "/dev/null"
    hunks = git_no_index_hunks(old_path, new_path)
  else
    hunks = vim.diff(before_text, after_text, { result_type = "unified", ctxlen = 3 })
  end
  if not hunks or hunks == "" then
    return nil
  end

  local header = string.format("diff --git a/%s b/%s", rel, rel)
  local old_label = before and ("a/" .. rel) or "/dev/null"
  local new_label = after and ("b/" .. rel) or "/dev/null"
  return string.format("%s\n--- %s\n+++ %s\n%s", header, old_label, new_label, hunks:gsub("\n$", ""))
end

---リクエストの差分を生成する
---@param handle_id string|nil リクエストのハンドルID
---@param base_dir string patch内パスの基準ディレクトリ（絶対パス）
---@param extra_paths table<string, boolean>|nil ツールイベント由来の変更ファイル（絶対/相対パス→true）。
---  フックで退避できなかったファイルもModified Files一覧には必ず含めるための補完。
---@return string[] files 変更ファイルの相対パス一覧（表示用）
---@return string[] abs_files 変更ファイルの絶対パス一覧（バッファリロード用）
---@return string|nil patch_content patch内容（diffを1つも生成できなければnil）
function M.generate(handle_id, base_dir, extra_paths)
  local files = {}
  local abs_files = {}
  local sections = {}
  local seen = {}

  local s = handle_id and sessions[handle_id] or nil
  if s then
    for _, abs in ipairs(s.order) do
      local entry = s.files[abs]
      local before = nil
      if entry.existed and entry.backup_path then
        before = read_file(entry.backup_path)
      end
      local after = read_file(abs)
      local rel, under_base = to_rel(abs, base_dir)
      local changed = (before or "") ~= (after or "")
      -- base_dir外のファイルはgit apply（cwd=base_dir、-p1）で復元できるpatchにならないため、
      -- 一覧にのみ載せてdiffセクションは作らない（バイナリも同様、build_file_section内で除外）
      local section = under_base and build_file_section(rel, entry, abs, before, after) or nil
      if section or changed then
        seen[abs] = true
        table.insert(files, rel)
        table.insert(abs_files, abs)
        if section then
          table.insert(sections, section)
        end
      end
    end
  end

  -- フックを通らなかった変更ファイル（退避なし）も一覧にだけは載せる
  for path in pairs(extra_paths or {}) do
    local abs = vim.fn.fnamemodify(path, ":p")
    if not seen[abs] and not (s and s.files[abs]) then
      seen[abs] = true
      local rel = to_rel(abs, base_dir)
      table.insert(files, rel)
      table.insert(abs_files, abs)
    end
  end

  local patch_content = nil
  if #sections > 0 then
    patch_content = string.format(
      "# vibing-request-diff base: %s\n%s\n",
      base_dir,
      table.concat(sections, "\n")
    )
  end

  return files, abs_files, patch_content
end

---リクエストのバックアップを破棄する（レスポンス処理の最後に必ず呼ぶ）
---@param handle_id string|nil
function M.clear(handle_id)
  if not handle_id then
    return
  end
  local s = sessions[handle_id]
  if not s then
    return
  end
  if s.dir then
    vim.fn.delete(s.dir, "rf")
  end
  sessions[handle_id] = nil
end

---テスト用: 退避済みかどうか
---@param handle_id string
---@param path string
---@return boolean
function M.has_capture(handle_id, path)
  local s = sessions[handle_id]
  if not s then
    return false
  end
  return s.files[vim.fn.fnamemodify(path, ":p")] ~= nil
end

return M
