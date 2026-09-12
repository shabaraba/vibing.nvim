---@class Vibing.PatchViewer.Parser
local M = {}

---@param patch_filename string
---@return string|nil
function M.resolve_patch_path(patch_filename)
  if vim.fn.filereadable(patch_filename) == 1 then
    return patch_filename
  end
  return nil
end

---@param patch_path string
---@return string|nil
function M.read_patch_file(patch_path)
  if vim.fn.filereadable(patch_path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(patch_path), "\n")
end

---@param file string
---@param cwd string
---@param cwd_without_slash string
---@return string
local function normalize_file_path(file, cwd, cwd_without_slash)
  if file:find(cwd_without_slash, 1, true) then
    local start_pos = file:find(cwd_without_slash, 1, true)
    return file:sub(start_pos + #cwd_without_slash + 1)
  elseif file:sub(1, 1) == "/" and file:find(cwd, 1, true) then
    return file:sub(#cwd + 2)
  end
  return file
end

---@param patch_content string
---@return string[]
function M.extract_files(patch_content)
  local files = {}
  local seen = {}
  local cwd = vim.fn.getcwd()
  local cwd_without_slash = cwd:sub(2)

  for line in patch_content:gmatch("[^\r\n]+") do
    -- `diff --mote` は削除されたmote統合が書いたpatchのヘッダ。保存済みチャットの
    -- `<!-- patch: ... -->` から今も開かれうるので、表示できるよう読めるままにしておく
    local file = line:match("^diff %-%-git a/(.+) b/") or line:match("^diff %-%-mote a/(.+) b/")
    if file then
      file = normalize_file_path(file, cwd, cwd_without_slash)
      if not seen[file] then
        seen[file] = true
        table.insert(files, file)
      end
    end
  end

  return files
end

---@param patch_content string
---@param target_file string
---@return string?
function M.extract_file_diff(patch_content, target_file)
  local lines = vim.split(patch_content, "\n", { plain = true })
  local result = {}
  local in_target_file = false
  local target_normalized = vim.fn.fnamemodify(target_file, ":.")
  local cwd = vim.fn.getcwd()
  local cwd_without_slash = cwd:sub(2)

  for _, line in ipairs(lines) do
    local diff_file = line:match("^diff %-%-git a/(.+) b/") or line:match("^diff %-%-mote a/(.+) b/")
    if diff_file then
      local diff_normalized = normalize_file_path(diff_file, cwd, cwd_without_slash)
      if diff_normalized == diff_file then
        diff_normalized = vim.fn.fnamemodify(diff_file, ":.")
      end

      if diff_normalized == target_normalized or diff_file == target_file then
        in_target_file = true
        table.insert(result, line)
      else
        in_target_file = false
      end
    elseif in_target_file then
      table.insert(result, line)
    end
  end

  if #result == 0 then
    return nil
  end
  return table.concat(result, "\n")
end

---一覧に出す変更量。`git diff --stat` と同じ数え方（ヘッダ行は数えない）
---@param patch_content string
---@param display_file string
---@return { status: "A"|"D"|"M", added: number, removed: number }
function M.file_stats(patch_content, display_file)
  local stats = { status = "M", added = 0, removed = 0 }

  local file_diff = M.extract_file_diff(patch_content, display_file)
  if not file_diff then
    return stats
  end

  for _, line in ipairs(vim.split(file_diff, "\n", { plain = true })) do
    if line:match("^new file mode") then
      stats.status = "A"
    elseif line:match("^deleted file mode") then
      stats.status = "D"
    elseif line:match("^%+%+%+ ") or line:match("^%-%-%- ") then
      -- `+++ b/path` / `--- a/path` はヘッダ。1行目と数え違えやすい
    elseif line:sub(1, 1) == "+" then
      stats.added = stats.added + 1
    elseif line:sub(1, 1) == "-" then
      stats.removed = stats.removed + 1
    end
  end

  return stats
end

---一覧は j/k のたびに描き直すので、数えるのは開く時の一度だけにする
---@param patch_content string
---@param files string[]
---@return table[] `files` と同じ並び
function M.all_stats(patch_content, files)
  local stats = {}
  for i, file in ipairs(files) do
    stats[i] = M.file_stats(patch_content, file)
  end
  return stats
end

---表示名から、patchに現れる **生のパス** を引き直す
---
---`extract_files` はNeovimのcwd相対に正規化してしまうが、`git apply` に渡すツリー上の位置は
---patch内の表記そのもの。base_dirはcwdと一致しないことがある（worktree、`working_dir` 指定）
---ので、正規化済みの値からは復元できない。
---@param patch_content string
---@param display_file string `extract_files` が返した表示名
---@return string|nil
function M.raw_path(patch_content, display_file)
  local cwd = vim.fn.getcwd()
  local cwd_without_slash = cwd:sub(2)

  for line in patch_content:gmatch("[^\r\n]+") do
    local raw = line:match("^diff %-%-git a/(.+) b/") or line:match("^diff %-%-mote a/(.+) b/")
    if raw and (raw == display_file or normalize_file_path(raw, cwd, cwd_without_slash) == display_file) then
      return raw
    end
  end
  return nil
end

---vibing.nvimが生成したpatchの基準ディレクトリ（`git apply -p1` を回すcwd）を抽出
---@param patch_content string
---@return string?
function M.extract_base_dir(patch_content)
  return patch_content:match("^# vibing%-request%-diff base: ([^\n]+)")
end

return M
