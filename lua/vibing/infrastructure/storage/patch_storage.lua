---@class Vibing.Infrastructure.PatchStorage
---patchファイルを使用したdiff情報の永続化
local M = {}

local PATCHES_DIR = ".vibing/patches"

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
  return filename:match("^[%d%-T]+%.patch$") ~= nil
end

---patchファイルのディレクトリパスを取得
---@param session_id string セッションID
---@return string dir_path
local function get_patch_dir(session_id)
  return string.format("%s/%s/%s", vim.fn.getcwd(), PATCHES_DIR, session_id)
end

---patchファイルのパスを生成
---@param session_id string セッションID
---@param timestamp? number タイムスタンプ（省略時は現在時刻）
---@return string patch_path
local function generate_patch_path(session_id, timestamp)
  timestamp = timestamp or os.time()
  local datetime = os.date("%Y-%m-%dT%H-%M-%S", timestamp)
  return string.format("%s/%s.patch", get_patch_dir(session_id), datetime)
end

---git diffを実行してpatchを生成
---@param files string[] 対象ファイルのリスト
---@return string? patch_content パッチ内容（失敗時はnil）
local function generate_patch(files)
  if not files or #files == 0 then
    return nil
  end

  -- ファイルパスをスペース区切りで結合
  local file_args = {}
  for _, file in ipairs(files) do
    table.insert(file_args, vim.fn.shellescape(file))
  end

  -- git diff（ステージングされていない変更）と git diff --cached（ステージング済み変更）を取得
  -- また、新規ファイルは git diff --no-index で差分を取得
  local patches = {}

  -- 既存ファイルの変更を取得（ステージング済み + 未ステージング）
  local cmd = string.format("git diff HEAD -- %s", table.concat(file_args, " "))
  local result = vim.fn.system({ "sh", "-c", cmd })
  if vim.v.shell_error ~= 0 then
    -- git diffエラー時はデバッグログ出力（通常の使用では発生しないはず）
    vim.schedule(function()
      vim.notify("git diff failed for existing files", vim.log.levels.DEBUG)
    end)
  elseif result and vim.trim(result) ~= "" then
    table.insert(patches, result)
  end

  -- 新規ファイル（untracked）の差分を生成
  for _, file in ipairs(files) do
    local normalized = vim.fn.fnamemodify(file, ":p")
    -- gitで追跡されていないファイルかチェック
    local check_cmd = string.format("git ls-files --error-unmatch %s 2>/dev/null", vim.fn.shellescape(normalized))
    vim.fn.system({ "sh", "-c", check_cmd })
    if vim.v.shell_error ~= 0 and vim.fn.filereadable(normalized) == 1 then
      -- 新規ファイル: /dev/null との差分を生成
      local diff_cmd = string.format("git diff --no-index /dev/null %s 2>/dev/null || true", vim.fn.shellescape(normalized))
      local diff_result = vim.fn.system({ "sh", "-c", diff_cmd })
      if diff_result and vim.trim(diff_result) ~= "" then
        table.insert(patches, diff_result)
      end
    end
  end

  if #patches == 0 then
    return nil
  end

  return table.concat(patches, "\n")
end

---patchファイルを保存
---@param session_id string セッションID
---@param modified_files string[] 変更されたファイルのリスト
---@return string? patch_filename 保存されたpatchファイル名（ディレクトリなし）
function M.save(session_id, modified_files)
  if not is_valid_session_id(session_id) then
    vim.schedule(function()
      vim.notify("Invalid session_id", vim.log.levels.ERROR)
    end)
    return nil
  end

  local patch_content = generate_patch(modified_files)
  if not patch_content then
    return nil
  end

  -- ディレクトリを作成
  local patch_dir = get_patch_dir(session_id)
  local mkdir_result = vim.fn.mkdir(patch_dir, "p")
  if mkdir_result == 0 and vim.fn.isdirectory(patch_dir) ~= 1 then
    vim.schedule(function()
      vim.notify("Failed to create patch directory", vim.log.levels.ERROR)
    end)
    return nil
  end

  -- patchファイルを保存
  local patch_path = generate_patch_path(session_id)
  local ok, err = pcall(function()
    local file = io.open(patch_path, "w")
    if file then
      file:write(patch_content)
      file:close()
    else
      error("Failed to open file for writing: " .. patch_path)
    end
  end)

  if not ok then
    vim.schedule(function()
      vim.notify("Failed to save patch: " .. tostring(err), vim.log.levels.WARN)
    end)
    return nil
  end

  -- ファイル名のみを返す（ディレクトリなし）
  return vim.fn.fnamemodify(patch_path, ":t")
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
