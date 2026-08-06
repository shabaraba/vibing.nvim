---@class Vibing.PatchViewer.Revert
local M = {}

local parser = require("vibing.ui.patch_viewer.parser")

---@param context_dir string
---@param snapshot_id string
---@param file string
---@return boolean success
---@return string? error_message
local function restore_file(context_dir, snapshot_id, file)
  local Binary = require("vibing.core.utils.mote.binary")
  local mote_bin = Binary.get_path()

  local cmd = string.format(
    "%s -d %s snap restore -f %s %s",
    vim.fn.shellescape(mote_bin),
    vim.fn.shellescape(context_dir),
    vim.fn.shellescape(file),
    vim.fn.shellescape(snapshot_id)
  )

  local result = vim.fn.system({ "sh", "-c", cmd })
  if vim.v.shell_error ~= 0 then
    return false, vim.trim(result or "")
  end
  return true, nil
end

---request_diff形式のpatch（git形式）の1ファイル分diffをリバース適用して変更を取り消す
---@param base_dir string patch内パスの基準ディレクトリ
---@param file_diff string 対象ファイルのdiffセクション
---@return boolean success
---@return string? error_message
local function reverse_apply(base_dir, file_diff)
  local tmp = vim.fn.tempname()
  local f = io.open(tmp, "w")
  if not f then
    return false, "Failed to create temp file"
  end
  f:write(file_diff)
  if not file_diff:match("\n$") then
    f:write("\n")
  end
  f:close()

  local result = vim
    .system({ "git", "apply", "--reverse", "--whitespace=nowarn", tmp }, { cwd = base_dir, text = true })
    :wait()
  os.remove(tmp)

  if result.code ~= 0 then
    return false, vim.trim(result.stderr or "")
  end
  return true, nil
end

---@class Vibing.PatchViewer.RevertContext
---@field kind "mote"|"request_diff"
---@field snapshot_id string? moteスナップショットID（kind="mote"）
---@field context_dir string? moteコンテキストディレクトリ（kind="mote"）
---@field base_dir string? patch基準ディレクトリ（kind="request_diff"）
---@field patch_content string

---@param patch_filename string
---@return Vibing.PatchViewer.RevertContext? ctx
---@return string? error
local function prepare_revert(patch_filename)
  local patch_path = parser.resolve_patch_path(patch_filename)
  if not patch_path then
    return nil, "Patch file not found: " .. patch_filename
  end

  local patch_content = parser.read_patch_file(patch_path)
  if not patch_content then
    return nil, "Failed to read patch file: " .. patch_filename
  end

  -- request_diff形式（git形式patch + baseヘッダ）: git applyでリバース適用できる
  local base_dir = parser.extract_base_dir(patch_content)
  if base_dir then
    return { kind = "request_diff", base_dir = base_dir, patch_content = patch_content }, nil
  end

  -- mote形式: スナップショットからrestoreする
  local snapshot_id = parser.extract_snapshot_id(patch_content)
  if not snapshot_id then
    return nil, "Failed to extract snapshot ID from patch"
  end

  local context_dir = parser.extract_context_dir(patch_path)
  if not context_dir then
    return nil, "Failed to extract context directory from patch path"
  end

  local Binary = require("vibing.core.utils.mote.binary")
  if not Binary.is_available() then
    return nil, "mote binary not found. Cannot revert patch."
  end

  return { kind = "mote", snapshot_id = snapshot_id, context_dir = context_dir, patch_content = patch_content }, nil
end

---patch形式に応じて1ファイルを差し戻す
---@param ctx Vibing.PatchViewer.RevertContext
---@param file string
---@return boolean success
---@return string? error_message
local function revert_one(ctx, file)
  if ctx.kind == "request_diff" then
    local file_diff = parser.extract_file_diff(ctx.patch_content, file)
    if not file_diff then
      return false, "No diff found in patch for: " .. file
    end
    return reverse_apply(ctx.base_dir, file_diff)
  end
  return restore_file(ctx.context_dir, ctx.snapshot_id, file)
end

---patch内の相対パスをバッファリロード用に解決する
---request_diff形式のpatchはbase_dir相対（git applyがcwd=base_dirで動くため）なので、
---Neovimのcwdと異なっていても正しいファイルをリロードできるよう絶対パスに直す
---@param ctx Vibing.PatchViewer.RevertContext
---@param file string patch内の相対パス
---@return string リロードに使うパス
local function resolve_reload_path(ctx, file)
  if ctx.kind == "request_diff" and ctx.base_dir and file:sub(1, 1) ~= "/" then
    return ctx.base_dir .. "/" .. file
  end
  return file
end

---@param _ string
---@param patch_filename string
---@param selected_file string
---@return boolean
function M.revert_single_file(_, patch_filename, selected_file)
  local ctx, err = prepare_revert(patch_filename)
  if not ctx then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  local success, error_msg = revert_one(ctx, selected_file)
  if not success then
    vim.notify(
      string.format("Failed to revert %s:\n%s", selected_file, error_msg or ""),
      vim.log.levels.ERROR
    )
    return false
  end

  local BufferReload = require("vibing.core.utils.buffer_reload")
  BufferReload.reload_files({ resolve_reload_path(ctx, selected_file) })

  vim.notify(string.format("Reverted %s", selected_file), vim.log.levels.INFO)
  return true
end

---@param _ string
---@param patch_filename string
---@return boolean
function M.revert_all_files(_, patch_filename)
  local ctx, err = prepare_revert(patch_filename)
  if not ctx then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  local files = parser.extract_files(ctx.patch_content)
  if #files == 0 then
    vim.notify("No files to revert", vim.log.levels.WARN)
    return false
  end

  local failed_files = {}
  local success_count = 0

  for _, file in ipairs(files) do
    local success, error_msg = revert_one(ctx, file)
    if not success then
      table.insert(failed_files, { file = file, error = error_msg })
    else
      success_count = success_count + 1
    end
  end

  M._report_results(files, failed_files, success_count)
  M._reload_successful_files(files, failed_files, success_count, ctx)

  return success_count > 0
end

---@param files string[]
---@param failed_files { file: string, error: string? }[]
---@param success_count number
function M._report_results(files, failed_files, success_count)
  if #failed_files > 0 then
    local error_msg = string.format("Reverted %d/%d files. Failed files:\n", success_count, #files)
    for _, failure in ipairs(failed_files) do
      error_msg = error_msg .. string.format("  - %s: %s\n", failure.file, failure.error or "unknown error")
    end
    vim.notify(error_msg, vim.log.levels.WARN)
  else
    vim.notify(string.format("Reverted all %d file(s)", #files), vim.log.levels.INFO)
  end
end

---@param files string[]
---@param failed_files { file: string, error: string? }[]
---@param success_count number
---@param ctx Vibing.PatchViewer.RevertContext|nil
function M._reload_successful_files(files, failed_files, success_count, ctx)
  if success_count == 0 then
    return
  end

  local failed_set = {}
  for _, failure in ipairs(failed_files) do
    failed_set[failure.file] = true
  end

  local success_files = {}
  for _, file in ipairs(files) do
    if not failed_set[file] then
      table.insert(success_files, ctx and resolve_reload_path(ctx, file) or file)
    end
  end

  local BufferReload = require("vibing.core.utils.buffer_reload")
  BufferReload.reload_files(success_files)
end

return M
