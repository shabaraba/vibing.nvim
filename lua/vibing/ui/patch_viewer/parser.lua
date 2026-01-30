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

---@param patch_content string
---@return string?
function M.extract_snapshot_id(patch_content)
  local first_line = patch_content:match("^([^\n]+)")
  if not first_line then
    return nil
  end
  return first_line:match("^Comparing (%w+) %-> working directory")
end

---@param patch_path string
---@return string?
function M.extract_context_dir(patch_path)
  return patch_path:match("(.+)/patches/")
end

return M
