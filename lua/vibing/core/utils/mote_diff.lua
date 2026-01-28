---@class Vibing.Utils.MoteDiff
---mote diff表示のユーティリティ
local M = {}

---Worktree固有のコンテキスト名を生成
---mote v0.2.0: --context API対応
---
---同じworktree内の全セッションは同じmote contextを共有します。
---これにより、worktree内での作業履歴を一貫して追跡できます。
---
---@param context_prefix string コンテキスト名のプレフィックス
---@param cwd? string 作業ディレクトリ（worktree判定用）
---@return string Worktree固有のコンテキスト名
function M.build_context_name(context_prefix, cwd)
  -- cwdがworktreeパス配下の場合、worktree名を抽出
  if cwd then
    local worktree_path = cwd:match("%.worktrees/(.+)")
    if worktree_path then
      -- mote contextのネーミングルールに従う
      -- ASCII文字、数字、ハイフン、アンダースコア、ドットのみ許可
      local worktree_name = worktree_path
        :gsub("[/\\:]", "-")        -- パス区切りとコロン
        :gsub("%s+", "-")           -- 空白文字
        :gsub("[^%w%-%_%.]+", "-")  -- ASCII文字/数字/ハイフン/アンダースコア/ドット以外
        :gsub("%-+", "-")           -- 連続するハイフンを1つに
        :gsub("^%-", "")            -- 先頭のハイフンを削除
        :gsub("%-$", "")            -- 末尾のハイフンを削除
      return string.format("%s-worktree-%s", context_prefix, worktree_name)
    end
  end

  -- プロジェクトルートの場合
  return string.format("%s-root", context_prefix)
end

---gitリポジトリ名からプロジェクト名を取得
---@return string|nil プロジェクト名（取得できない場合nil）
function M.get_project_name()
  local Git = require("vibing.core.utils.git")
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end

  -- git rootディレクトリ名を使用
  return vim.fn.fnamemodify(git_root, ":t")
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

---moteコンテキストが初期化されているかチェック
---@param project string? プロジェクト名
---@param context string? コンテキスト名
---@return boolean moteコンテキストが初期化されている場合true
function M.is_initialized(project, context)
  if not M.is_available() then
    return false
  end

  -- mote context listを実行して、指定されたコンテキストが存在するかチェック
  local cmd = { M.get_mote_path(), "context", "list" }
  if project then
    table.insert(cmd, 2, "--project")
    table.insert(cmd, 3, project)
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false
  end

  -- コンテキスト名が出力に含まれているかチェック
  if context then
    return result:find(context, 1, true) ~= nil
  end

  -- コンテキスト名が指定されていない場合は、defaultが存在するかチェック
  return result:find("default", 1, true) ~= nil
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
---mote v0.2.0: --project/--context APIを使用
---@param config Vibing.MoteConfig mote設定
---@return string[] コマンドライン引数の配列
local function build_mote_base_args(config)
  local abs_ignore_file = vim.fn.fnamemodify(config.ignore_file, ":p")

  local cmd = { M.get_mote_path(), "--ignore-file", abs_ignore_file }

  -- プロジェクト名を追加（設定 or 自動検出）
  local project = config.project or M.get_project_name()
  if project then
    table.insert(cmd, "--project")
    table.insert(cmd, project)
  end

  -- コンテキスト名を追加（設定から取得）
  if config.context then
    table.insert(cmd, "--context")
    table.insert(cmd, config.context)
  end

  return cmd
end

---moteコマンドを実行し結果をコールバックで返す
---@param args string[] コマンドライン引数
---@param cwd string|nil 作業ディレクトリ（nilの場合は現在のディレクトリ）
---@param on_success fun(stdout: string) 成功時のコールバック
---@param on_error fun(error: string) エラー時のコールバック
local function run_mote_command(args, cwd, on_success, on_error)
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end
  vim.system(args, opts, function(obj)
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
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param callback fun(success: boolean, output: string?, error: string?) コールバック関数
function M.get_diff(file_path, config, callback)
  if not M.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  -- Ensure .moteignore exists even for already initialized storage
  M._ensure_moteignore_exists(config.ignore_file)

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, vim.fn.fnamemodify(file_path, ":p"))

  run_mote_command(cmd, config.cwd, function(stdout)
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
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)

    vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
      callback = function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end,
      noremap = true,
      silent = true,
    })
  end)
end

---プロジェクトローカルのcontext-dirパスを生成
---@param project string|nil プロジェクト名
---@param context string コンテキスト名
---@return string|nil context-dirのパス（git rootが取得できない場合nil）
function M.build_context_dir_path(project, context)
  local Git = require("vibing.core.utils.git")
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end

  local project_name = project or "default"
  return git_root .. "/.vibing/mote/" .. project_name .. "/" .. context
end

---mote storageを初期化
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param callback fun(success: boolean, error: string?) コールバック関数
function M.initialize(config, callback)
  if not M.is_available() then
    callback(false, "mote binary not found")
    return
  end

  -- Ensure .moteignore exists before checking initialization
  M._ensure_moteignore_exists(config.ignore_file)

  -- コンテキストが既に存在する場合はスキップ
  if M.is_initialized(config.project, config.context) then
    callback(true, nil)
    return
  end

  -- プロジェクトローカルのcontext-dirパスを生成
  local project = config.project or M.get_project_name()
  local context_dir = M.build_context_dir_path(project, config.context)
  if not context_dir then
    callback(false, "Failed to get git root directory")
    return
  end

  -- mote context new <context-name> --context-dir <path>を実行
  local cmd = { M.get_mote_path() }
  if project then
    table.insert(cmd, "--project")
    table.insert(cmd, project)
  end
  table.insert(cmd, "context")
  table.insert(cmd, "new")
  table.insert(cmd, config.context)
  table.insert(cmd, "--context-dir")
  table.insert(cmd, context_dir)

  run_mote_command(cmd, config.cwd, function()
    callback(true, nil)
  end, function(error)
    callback(false, error)
  end)
end

---mote snapshotを作成
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param message? string スナップショットメッセージ
---@param callback fun(success: boolean, snapshot_id: string?, error: string?) コールバック関数
function M.create_snapshot(config, message, callback)
  if not M.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  -- Ensure .moteignore exists even for already initialized storage
  M._ensure_moteignore_exists(config.ignore_file)

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "snapshot")
  table.insert(cmd, "--auto")

  if message then
    table.insert(cmd, "-m")
    table.insert(cmd, message)
  end

  run_mote_command(cmd, config.cwd, function(stdout)
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
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param callback fun(success: boolean, files: string[]?, error: string?) コールバック関数
function M.get_changed_files(config, callback)
  if not M.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  -- Ensure .moteignore exists even for already initialized storage
  M._ensure_moteignore_exists(config.ignore_file)

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, "--name-only")

  run_mote_command(cmd, config.cwd, function(stdout)
    callback(true, parse_changed_files(stdout), nil)
  end, function(error)
    callback(false, nil, error)
  end)
end

---patchファイルを生成
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param output_path string 出力先パス
---@param callback fun(success: boolean, error: string?) コールバック関数
function M.generate_patch(config, output_path, callback)
  if not M.is_available() then
    callback(false, "mote binary not found")
    return
  end

  -- Ensure .moteignore exists even for already initialized storage
  M._ensure_moteignore_exists(config.ignore_file)

  local output_dir = vim.fn.fnamemodify(output_path, ":h")
  vim.fn.mkdir(output_dir, "p")

  local cmd = build_mote_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, "-o")
  table.insert(cmd, output_path)

  run_mote_command(cmd, config.cwd, function()
    callback(true, nil)
  end, function(error)
    callback(false, error)
  end)
end

return M
