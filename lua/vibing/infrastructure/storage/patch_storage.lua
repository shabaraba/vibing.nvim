---@class Vibing.Infrastructure.PatchStorage
---patchファイルを使用したdiff情報の永続化
local M = {}

local PATCHES_DIR = ".vibing/patches"

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
  local cmd = string.format("git diff HEAD -- %s 2>/dev/null", table.concat(file_args, " "))
  local result = vim.fn.system({ "sh", "-c", cmd })
  if vim.v.shell_error == 0 and result and vim.trim(result) ~= "" then
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
  if not session_id or session_id == "" then
    return nil
  end

  local patch_content = generate_patch(modified_files)
  if not patch_content then
    return nil
  end

  -- ディレクトリを作成
  local patch_dir = get_patch_dir(session_id)
  vim.fn.mkdir(patch_dir, "p")

  -- patchファイルを保存
  local patch_path = generate_patch_path(session_id)
  local ok = pcall(function()
    local file = io.open(patch_path, "w")
    if file then
      file:write(patch_content)
      file:close()
    end
  end)

  if not ok then
    return nil
  end

  -- ファイル名のみを返す（ディレクトリなし）
  return vim.fn.fnamemodify(patch_path, ":t")
end

---saved_contentsからpatchを生成して保存（git操作前に呼ぶ）
---@param session_id string セッションID
---@param modified_files string[] 変更されたファイルのリスト
---@param saved_contents table<string, string[]> 変更前のファイル内容
---@return string? patch_filename 保存されたpatchファイル名（ディレクトリなし）
function M.save_from_contents(session_id, modified_files, saved_contents)
  if not session_id or session_id == "" then
    return nil
  end

  if not modified_files or #modified_files == 0 then
    return nil
  end

  local patches = {}

  for _, file in ipairs(modified_files) do
    local normalized = vim.fn.fnamemodify(file, ":p")
    local before_lines = saved_contents[normalized]

    -- 現在のファイル内容を取得
    local after_lines = {}
    if vim.fn.filereadable(normalized) == 1 then
      after_lines = vim.fn.readfile(normalized)
    end

    -- before_linesがない場合はスキップ
    if not before_lines then
      goto continue
    end

    -- 一時ファイルを使ってdiffを生成
    local tmp_before = vim.fn.tempname()
    local tmp_after = vim.fn.tempname()

    local ok, diff_result = pcall(function()
      vim.fn.writefile(before_lines, tmp_before)
      vim.fn.writefile(after_lines, tmp_after)

      local cmd = string.format(
        "git diff --no-index --no-color %s %s 2>/dev/null || true",
        vim.fn.shellescape(tmp_before),
        vim.fn.shellescape(tmp_after)
      )
      return vim.fn.system({ "sh", "-c", cmd })
    end)

    -- 一時ファイルをクリーンアップ
    vim.fn.delete(tmp_before)
    vim.fn.delete(tmp_after)

    if ok and diff_result and vim.trim(diff_result) ~= "" then
      -- 一時ファイルパスを実際のファイルパスに置換
      -- git diff --no-index は a/<path> b/<path> 形式で出力するので、
      -- a/<tmp> -> a/<relative_path> のように置換する
      local relative_path = vim.fn.fnamemodify(file, ":.")
      diff_result = diff_result:gsub("a/" .. vim.pesc(tmp_before), "a/" .. relative_path)
      diff_result = diff_result:gsub("b/" .. vim.pesc(tmp_after), "b/" .. relative_path)
      -- --- と +++ 行も置換
      diff_result = diff_result:gsub("%-%-% a/" .. vim.pesc(tmp_before), "--- a/" .. relative_path)
      diff_result = diff_result:gsub("%+%+%+ b/" .. vim.pesc(tmp_after), "+++ b/" .. relative_path)
      table.insert(patches, diff_result)
    end

    ::continue::
  end

  if #patches == 0 then
    return nil
  end

  local patch_content = table.concat(patches, "\n")

  -- ディレクトリを作成
  local patch_dir = get_patch_dir(session_id)
  vim.fn.mkdir(patch_dir, "p")

  -- patchファイルを保存
  local patch_path = generate_patch_path(session_id)
  local write_ok = pcall(function()
    local file = io.open(patch_path, "w")
    if file then
      file:write(patch_content)
      file:close()
    end
  end)

  if not write_ok then
    return nil
  end

  return vim.fn.fnamemodify(patch_path, ":t")
end

---patchファイルを読み込み
---@param session_id string セッションID
---@param patch_filename string patchファイル名
---@return string? patch_content パッチ内容
function M.read(session_id, patch_filename)
  if not session_id or not patch_filename then
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
  if not session_id or not patch_filename then
    return false
  end

  local patch_path = string.format("%s/%s", get_patch_dir(session_id), patch_filename)

  if vim.fn.filereadable(patch_path) ~= 1 then
    return false
  end

  -- git apply -R でパッチを逆適用
  local cmd = string.format("git apply -R %s 2>/dev/null", vim.fn.shellescape(patch_path))
  vim.fn.system({ "sh", "-c", cmd })

  return vim.v.shell_error == 0
end

---セッションのpatchディレクトリを削除
---@param session_id string セッションID
---@return boolean success
function M.delete_session(session_id)
  if not session_id or session_id == "" then
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
  if not session_id or session_id == "" then
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
