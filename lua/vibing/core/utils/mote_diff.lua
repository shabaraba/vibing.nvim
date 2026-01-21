---@class Vibing.Utils.MoteDiff
---mote diff表示のユーティリティ
local M = {}

---セッション固有のstorage_dirを生成
---@param base_storage_dir string ベースのstorage_dir
---@param session_id? string セッションID
---@return string セッション固有のstorage_dir（session_idがnilの場合はbase_storage_dirをそのまま返す）
function M.build_session_storage_dir(base_storage_dir, session_id)
  if session_id then
    return string.format(".vibing/mote/%s", session_id)
  end
  return base_storage_dir
end

---プラットフォームに応じたmoteバイナリパスを取得
---vibing.nvim同梱のバイナリを優先的に使用し、見つからない場合のみPATHから探す
---@return string|nil moteバイナリのパス（見つからない場合nil）
function M.get_mote_path()
  -- vibing.nvim同梱のmoteバイナリを優先的に探す
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(script_path, ":h:h:h:h:h")

  -- プラットフォーム検出
  local platform = vim.loop.os_uname().sysname:lower()
  local arch = vim.loop.os_uname().machine:lower()

  local platform_map = {
    ["darwin-arm64"] = "darwin-arm64",
    ["darwin-aarch64"] = "darwin-arm64",
    ["darwin-x86_64"] = "darwin-x64",
    ["linux-aarch64"] = "linux-arm64",
    ["linux-x86_64"] = "linux-x64",
  }

  local platform_key = platform_map[platform .. "-" .. arch]
  if platform_key then
    local bundled_mote = plugin_root .. "/bin/mote-" .. platform_key
    if vim.fn.executable(bundled_mote) == 1 then
      return bundled_mote
    end
  end

  -- 同梱バイナリが見つからない場合のみPATHから探す
  if vim.fn.executable("mote") == 1 then
    return "mote"
  end

  return nil
end

---moteが利用可能かチェック
---@return boolean moteが実行可能な場合true
function M.is_available()
  return M.get_mote_path() ~= nil
end

---moteが初期化されているかチェック
---@param cwd string? チェックするディレクトリ（デフォルト: 現在のディレクトリ）
---@param storage_dir string? moteストレージディレクトリ（設定から渡される）
---@return boolean moteが初期化されている場合true
function M.is_initialized(cwd, storage_dir)
  if storage_dir then
    return M._check_storage_dir_initialized(storage_dir)
  end
  return M._check_legacy_paths(cwd or vim.fn.getcwd())
end

---指定されたstorage_dirが初期化済みかチェック
---@param storage_dir string moteストレージディレクトリ
---@return boolean
function M._check_storage_dir_initialized(storage_dir)
  local abs_path = vim.fn.fnamemodify(storage_dir, ":p"):gsub("/$", "")
  local has_snapshots = vim.fn.isdirectory(abs_path .. "/snapshots") == 1
  local has_objects = vim.fn.isdirectory(abs_path .. "/objects") == 1
  return has_snapshots and has_objects
end

---レガシーパス（.mote, .git/mote）をチェック
---@param cwd string チェックするディレクトリ
---@return boolean
function M._check_legacy_paths(cwd)
  local mote_dir = vim.fn.finddir(".mote", cwd .. ";")
  local git_mote_dir = vim.fn.finddir(".git/mote", cwd .. ";")
  return mote_dir ~= "" or git_mote_dir ~= ""
end

---デフォルトの.moteignoreルール
local DEFAULT_MOTEIGNORE_RULES = {
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
function M._ensure_moteignore_exists(ignore_file_path)
  local abs_path = vim.fn.fnamemodify(ignore_file_path, ":p")

  if vim.fn.filereadable(abs_path) == 1 then
    return
  end

  local parent_dir = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(parent_dir, "p")

  vim.fn.writefile(DEFAULT_MOTEIGNORE_RULES, abs_path)
end

---moteコマンドのベース引数を生成
---@param config Vibing.MoteConfig mote設定
---@return string[] コマンドライン引数の配列
local function build_mote_base_args(config)
  return {
    M.get_mote_path(),
    "--ignore-file",
    config.ignore_file,
    "--storage-dir",
    config.storage_dir,
  }
end

---moteコマンドを実行し結果をコールバックで返す
---@param args string[] コマンドライン引数
---@param on_success fun(stdout: string) 成功時のコールバック
---@param on_error fun(error: string) エラー時のコールバック
local function run_mote_command(args, on_success, on_error)
  vim.system(args, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        on_error(obj.stderr or "Unknown error")
        return
      end
      on_success(obj.stdout or "")
    end)
  end)
end

---mote diffコマンドを実行してdiffを取得
---@param file_path string ファイルパス（絶対パス）
---@param config Vibing.MoteConfig mote設定
---@param callback fun(success: boolean, output: string?, error: string?) コールバック関数
function M.get_diff(file_path, config, callback)
  if not M.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, vim.fn.fnamemodify(file_path, ":p"))

  run_mote_command(cmd, function(stdout)
    callback(true, stdout, nil)
  end, function(error)
    callback(false, nil, error)
  end)
end

---ファイルのmote diffを表示
---@param file_path string ファイルパス（絶対パス）
---@param config Vibing.MoteConfig mote設定
function M.show_diff(file_path, config)
  M.get_diff(file_path, config, function(success, output, error)
    if not success then
      if error and error:match("not initialized") then
        vim.notify("[vibing] mote not initialized", vim.log.levels.ERROR)
      elseif error and (error:match("Snapshot not found") or error:match("does not exist")) then
        vim.notify("[vibing] No mote snapshot found for: " .. file_path, vim.log.levels.INFO)
      else
        vim.notify("[vibing] mote diff failed: " .. (error or "Unknown error"), vim.log.levels.ERROR)
      end
      return
    end

    if not output or output == "" or output:match("^%s*$") then
      vim.notify("[vibing] No changes to show", vim.log.levels.INFO)
      return
    end

    local Factory = require("vibing.infrastructure.ui.factory")
    local buf = Factory.create_buffer({
      buftype = "nofile",
      bufhidden = "wipe",
      filetype = "diff",
      modifiable = true,
    })

    local lines = vim.split(output, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_set_current_buf(buf)

    vim.keymap.set("n", "q", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, noremap = true, silent = true })

    vim.keymap.set("n", "<Esc>", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, noremap = true, silent = true })
  end)
end

---mote storageを初期化
---@param config Vibing.MoteConfig mote設定
---@param callback fun(success: boolean, error: string?) コールバック関数
function M.initialize(config, callback)
  if not M.is_available() then
    callback(false, "mote binary not found")
    return
  end

  if M.is_initialized(nil, config.storage_dir) then
    callback(true, nil)
    return
  end

  M._ensure_moteignore_exists(config.ignore_file)

  local parent_dir = vim.fn.fnamemodify(config.storage_dir, ":h")
  vim.fn.mkdir(parent_dir, "p")

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "init")

  run_mote_command(cmd, function()
    callback(true, nil)
  end, function(error)
    callback(false, error)
  end)
end

---mote snapshotを作成
---@param config Vibing.MoteConfig mote設定
---@param message? string スナップショットメッセージ
---@param callback fun(success: boolean, snapshot_id: string?, error: string?) コールバック関数
function M.create_snapshot(config, message, callback)
  if not M.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "snapshot")
  table.insert(cmd, "--auto")

  if message then
    table.insert(cmd, "-m")
    table.insert(cmd, message)
  end

  run_mote_command(cmd, function(stdout)
    local snapshot_id = stdout:match("snapshot%s+(%w+)")
    callback(true, snapshot_id, nil)
  end, function(error)
    callback(false, nil, error)
  end)
end

---diff出力からファイルパスを抽出
---@param output string mote diff --name-onlyの出力
---@return string[] ファイルパスの配列
local function parse_changed_files(output)
  if output == "" or output:match("^%s*$") then
    return {}
  end

  local files = {}
  for line in output:gmatch("[^\r\n]+") do
    if line ~= "" and not line:match("^Comparing") and not line:match("^%s*$") then
      local file_path = line:match("^[MAD]%s+(.+)$")
      if file_path then
        table.insert(files, file_path)
      elseif not line:match("^[MAD]%s+") then
        table.insert(files, line)
      end
    end
  end
  return files
end

---変更されたファイル一覧を取得
---@param config Vibing.MoteConfig mote設定
---@param callback fun(success: boolean, files: string[]?, error: string?) コールバック関数
function M.get_changed_files(config, callback)
  if not M.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, "--name-only")

  run_mote_command(cmd, function(stdout)
    callback(true, parse_changed_files(stdout), nil)
  end, function(error)
    callback(false, nil, error)
  end)
end

---patchファイルを生成
---@param config Vibing.MoteConfig mote設定
---@param output_path string 出力先パス
---@param callback fun(success: boolean, error: string?) コールバック関数
function M.generate_patch(config, output_path, callback)
  if not M.is_available() then
    callback(false, "mote binary not found")
    return
  end

  local output_dir = vim.fn.fnamemodify(output_path, ":h")
  vim.fn.mkdir(output_dir, "p")

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, "-o")
  table.insert(cmd, output_path)

  run_mote_command(cmd, function()
    callback(true, nil)
  end, function(error)
    callback(false, error)
  end)
end

---一時ストレージディレクトリを正式なsession_idディレクトリにリネーム
---@param temp_storage_dir string 一時ストレージディレクトリ
---@param session_id string 正式なsession_id
---@param base_storage_dir string ベースのstorage_dir（例: ".vibing/mote"）
---@return string 新しいstorage_dirパス
---@return boolean 成功したかどうか
function M.rename_storage_dir(temp_storage_dir, session_id, base_storage_dir)
  local new_storage_dir = M.build_session_storage_dir(base_storage_dir, session_id)

  -- 同じパスなら何もしない
  if temp_storage_dir == new_storage_dir then
    return new_storage_dir, true
  end

  local temp_abs = vim.fn.fnamemodify(temp_storage_dir, ":p"):gsub("/$", "")
  local new_abs = vim.fn.fnamemodify(new_storage_dir, ":p"):gsub("/$", "")

  -- 一時ディレクトリが存在しない場合
  if vim.fn.isdirectory(temp_abs) ~= 1 then
    return new_storage_dir, false
  end

  -- 新しいディレクトリが既に存在する場合は一時ディレクトリを削除
  if vim.fn.isdirectory(new_abs) == 1 then
    vim.fn.delete(temp_abs, "rf")
    return new_storage_dir, true
  end

  -- 親ディレクトリを作成
  local parent_dir = vim.fn.fnamemodify(new_abs, ":h")
  vim.fn.mkdir(parent_dir, "p")

  -- リネーム実行
  local result = vim.fn.rename(temp_abs, new_abs)
  if result == 0 then
    return new_storage_dir, true
  else
    return new_storage_dir, false
  end
end

return M
