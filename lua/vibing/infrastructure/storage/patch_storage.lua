---@class Vibing.Infrastructure.PatchStorage
---patchファイルを使用したdiff情報の永続化
local M = {}

---session_idの検証
---@param session_id string セッションID
---@return boolean valid
local function is_valid_session_id(session_id)
  if not session_id or session_id == "" then
    return false
  end
  -- 英数字、ハイフン、アンダースコアのみ許可（パストラバーサル防止）
  return session_id:match("^[%w%-_]+$") ~= nil
end

---patch_filenameの検証
---@param filename string ファイル名
---@return boolean valid
local function is_valid_patch_filename(filename)
  if not filename or filename == "" then
    return false
  end
  -- .patchファイルのみ許可、パス区切り文字を含まない
  -- ISO 8601形式: 2026-01-10T14-21-21-642Z.patch
  return filename:match("^[%d%-TZ]+%.patch$") ~= nil
end

---patchファイルのベースディレクトリを取得（chat保存場所と同じ設定を使用）
---@return string base_dir
local function get_patches_base_dir()
  local vibing = require("vibing")
  local config = vibing.get_config()
  local location_type = config.chat.save_location_type or "project"

  if location_type == "project" then
    return vim.fn.getcwd() .. "/.vibing/patches"
  elseif location_type == "user" then
    return vim.fn.stdpath("data") .. "/vibing/patches"
  elseif location_type == "custom" then
    local base_path = config.chat.save_dir or (vim.fn.getcwd() .. "/.vibing")
    -- Remove trailing /chats or /chat if present
    base_path = base_path:gsub("/chats?/?$", "")
    return base_path .. "/patches"
  else
    return vim.fn.getcwd() .. "/.vibing/patches"
  end
end

---patchファイルのディレクトリパスを取得
---@param session_id string セッションID
---@return string dir_path
local function get_patch_dir(session_id)
  return string.format("%s/%s", get_patches_base_dir(), session_id)
end

---patchファイルを読み込み
---@param session_id string セッションID
---@param patch_filename string patchファイル名
---@return string? patch_content パッチ内容
function M.read(session_id, patch_filename)
  if not is_valid_session_id(session_id) or not is_valid_patch_filename(patch_filename) then
    return nil
  end

  local patch_path = string.format("%s/%s", get_patch_dir(session_id), patch_filename)

  if vim.fn.filereadable(patch_path) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(patch_path)
  return table.concat(lines, "\n")
end

---patchを逆適用（revert）
---@param session_id string セッションID
---@param patch_filename string patchファイル名
---@return boolean success
function M.revert(session_id, patch_filename)
  if not is_valid_session_id(session_id) or not is_valid_patch_filename(patch_filename) then
    return false
  end

  local patch_path = string.format("%s/%s", get_patch_dir(session_id), patch_filename)

  if vim.fn.filereadable(patch_path) ~= 1 then
    return false
  end

  -- git apply -R でパッチを逆適用
  local cmd = string.format("git apply -R %s", vim.fn.shellescape(patch_path))
  local result = vim.fn.system({ "sh", "-c", cmd })

  if vim.v.shell_error ~= 0 then
    -- git apply失敗時はエラー内容をログ出力
    vim.schedule(function()
      vim.notify(
        string.format("git apply -R failed: %s", vim.trim(result or "")),
        vim.log.levels.DEBUG
      )
    end)
    return false
  end

  return true
end

---セッションのpatchディレクトリを削除
---@param session_id string セッションID
---@return boolean success
function M.delete_session(session_id)
  if not is_valid_session_id(session_id) then
    return false
  end

  local patch_dir = get_patch_dir(session_id)

  if vim.fn.isdirectory(patch_dir) ~= 1 then
    return true -- 既に存在しない
  end

  -- ディレクトリを再帰的に削除
  vim.fn.delete(patch_dir, "rf")

  return vim.fn.isdirectory(patch_dir) ~= 1
end

---セッションのpatchファイル一覧を取得
---@param session_id string セッションID
---@return string[] patch_files patchファイル名のリスト
function M.list(session_id)
  if not is_valid_session_id(session_id) then
    return {}
  end

  local patch_dir = get_patch_dir(session_id)

  if vim.fn.isdirectory(patch_dir) ~= 1 then
    return {}
  end

  local files = vim.fn.glob(patch_dir .. "/*.patch", false, true)
  local result = {}

  for _, file in ipairs(files) do
    table.insert(result, vim.fn.fnamemodify(file, ":t"))
  end

  -- タイムスタンプ順（ファイル名）でソート
  table.sort(result)

  return result
end

---patchファイルが存在するかチェック
---@param session_id string セッションID
---@param patch_filename string patchファイル名
---@return boolean exists
function M.exists(session_id, patch_filename)
  if not session_id or not patch_filename then
    return false
  end

  local patch_path = string.format("%s/%s", get_patch_dir(session_id), patch_filename)
  return vim.fn.filereadable(patch_path) == 1
end

return M
