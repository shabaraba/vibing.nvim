---@class Vibing.Utils.Mote.Moteignore
---.moteignoreファイルの管理
local M = {}

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

---コンテキストのignoreファイルに.vibing/を追加
---@param context_dir string コンテキストディレクトリのパス
function M.add_vibing_ignore(context_dir)
  local ignore_file_path = context_dir .. "/ignore"
  local ignore_file = io.open(ignore_file_path, "r")
  if not ignore_file then
    return
  end

  local content = ignore_file:read("*all")
  ignore_file:close()

  if content:match("%.vibing/") then
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

  table.insert(lines, insert_pos, "")
  table.insert(lines, insert_pos + 1, "# vibing.nvim internal files")
  table.insert(lines, insert_pos + 2, ".vibing/")

  local new_content = table.concat(lines, "\n")
  local write_file = io.open(ignore_file_path, "w")
  if write_file then
    write_file:write(new_content)
    write_file:close()
  end
end

return M
