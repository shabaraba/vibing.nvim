---@class Vibing.Utils.Mote.Moteignore
---.moteignoreファイルの管理
local M = {}

---cwdがworktree内かどうかを判定
---@param cwd string|nil 作業ディレクトリ
---@return boolean worktree内の場合true
local function is_worktree(cwd)
  if not cwd then
    return false
  end
  return cwd:match("%.worktrees/") ~= nil
end

---デフォルトの.moteignoreルール
M.DEFAULT_RULES = {
  "# vibing.nvim auto-generated .moteignore",
  "# Ignore .vibing directory contents (vibing.nvim internal files)",
  ".vibing/",
  "",
  "# Dependencies (large file count, causes slow snapshots)",
  "node_modules/",
  "**/node_modules/",
  "",
  "# Build outputs",
  "dist/",
  "build/",
  "",
  "# Version control",
  ".git/",
  "",
  "# Common cache/artifact directories",
  ".cache/",
  "coverage/",
  ".nyc_output/",
  "__pycache__/",
  "*.pyc",
  ".pytest_cache/",
  "target/",
  "",
}

---.moteignoreファイルが存在しない場合は自動作成
---@param ignore_file_path string .moteignoreファイルのパス
function M.ensure_exists(ignore_file_path)
  local abs_path = vim.fn.fnamemodify(ignore_file_path, ":p")

  if vim.fn.filereadable(abs_path) == 1 then
    return
  end

  local parent_dir = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(parent_dir, "p")

  vim.fn.writefile(M.DEFAULT_RULES, abs_path)
end

---コンテキストのignoreファイルに.vibing/と（mainの場合）.worktrees/を追加
---@param context_dir string コンテキストディレクトリのパス
---@param cwd string|nil 作業ディレクトリ（worktree判定用）
function M.add_vibing_ignore(context_dir, cwd)
  local ignore_file_path = context_dir .. "/ignore"
  local ignore_file = io.open(ignore_file_path, "r")
  if not ignore_file then
    return
  end

  local content = ignore_file:read("*all")
  ignore_file:close()

  local has_vibing = content:match("%.vibing/") ~= nil
  local has_worktrees = content:match("%.worktrees/") ~= nil
  local in_worktree = is_worktree(cwd)

  -- mainコンテキストでは.worktrees/も必要、worktreeコンテキストでは.vibing/のみ
  local need_vibing = not has_vibing
  local need_worktrees = not in_worktree and not has_worktrees

  if not need_vibing and not need_worktrees then
    return
  end

  local lines = vim.split(content, "\n")
  local insert_pos = nil

  for i, line in ipairs(lines) do
    if line:match("^# Uses gitignore syntax") then
      insert_pos = i + 1
      break
    end
  end

  if not insert_pos then
    return
  end

  while insert_pos <= #lines and lines[insert_pos] == "" do
    insert_pos = insert_pos + 1
  end

  local entries_to_add = {}
  table.insert(entries_to_add, "")
  table.insert(entries_to_add, "# vibing.nvim internal files")
  if need_vibing then
    table.insert(entries_to_add, ".vibing/")
  end
  if need_worktrees then
    table.insert(entries_to_add, ".worktrees/")
  end

  for i, entry in ipairs(entries_to_add) do
    table.insert(lines, insert_pos + i - 1, entry)
  end

  local new_content = table.concat(lines, "\n")
  local write_file = io.open(ignore_file_path, "w")
  if write_file then
    write_file:write(new_content)
    write_file:close()
  end
end

return M
