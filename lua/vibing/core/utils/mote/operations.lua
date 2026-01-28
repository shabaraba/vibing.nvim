---@class Vibing.Utils.Mote.Operations
---moteの各種操作（diff, snapshot, patch）
local M = {}

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

---mote diffコマンドを実行してdiffを取得
---@param file_path string ファイルパス（絶対パス）
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param callback fun(success: boolean, output: string?, error: string?) コールバック関数
function M.get_diff(file_path, config, callback)
  local Binary = require("vibing.core.utils.mote.binary")
  local Command = require("vibing.core.utils.mote.command")
  local Moteignore = require("vibing.core.utils.mote.moteignore")

  if not Binary.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  Moteignore.ensure_exists(config.ignore_file)

  local cmd = Command.build_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, vim.fn.fnamemodify(file_path, ":p"))

  Command.run(cmd, config.cwd, function(stdout)
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

---mote storageを初期化
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param callback fun(success: boolean, error: string?) コールバック関数
function M.initialize(config, callback)
  local Binary = require("vibing.core.utils.mote.binary")
  local Command = require("vibing.core.utils.mote.command")
  local Context = require("vibing.core.utils.mote.context")
  local Moteignore = require("vibing.core.utils.mote.moteignore")

  if not Binary.is_available() then
    callback(false, "mote binary not found")
    return
  end

  Moteignore.ensure_exists(config.ignore_file)

  if Context.is_initialized(config.project, config.context) then
    callback(true, nil)
    return
  end

  local project = config.project or Context.get_project_name()
  local context_dir = Context.build_dir_path(project, config.context)
  if not context_dir then
    callback(false, "Failed to get git root directory")
    return
  end

  local cmd = { Binary.get_path() }
  if project then
    table.insert(cmd, "--project")
    table.insert(cmd, project)
  end
  table.insert(cmd, "context")
  table.insert(cmd, "new")
  table.insert(cmd, config.context)
  table.insert(cmd, "--context-dir")
  table.insert(cmd, context_dir)

  Command.run(cmd, config.cwd, function()
    Moteignore.add_vibing_ignore(context_dir)
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
  local Binary = require("vibing.core.utils.mote.binary")
  local Command = require("vibing.core.utils.mote.command")
  local Moteignore = require("vibing.core.utils.mote.moteignore")

  if not Binary.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  Moteignore.ensure_exists(config.ignore_file)

  local cmd = Command.build_base_args(config)
  table.insert(cmd, "snapshot")
  table.insert(cmd, "--auto")

  if message then
    table.insert(cmd, "-m")
    table.insert(cmd, message)
  end

  Command.run(cmd, config.cwd, function(stdout)
    local snapshot_id = stdout:match("snapshot%s+(%w+)")
    callback(true, snapshot_id, nil)
  end, function(error)
    callback(false, nil, error)
  end)
end

---変更されたファイル一覧を取得
---@param config Vibing.MoteConfig mote設定（cwdフィールドを含む）
---@param callback fun(success: boolean, files: string[]?, error: string?) コールバック関数
function M.get_changed_files(config, callback)
  local Binary = require("vibing.core.utils.mote.binary")
  local Command = require("vibing.core.utils.mote.command")
  local Moteignore = require("vibing.core.utils.mote.moteignore")

  if not Binary.is_available() then
    callback(false, nil, "mote binary not found")
    return
  end

  Moteignore.ensure_exists(config.ignore_file)

  local cmd = Command.build_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, "--name-only")

  Command.run(cmd, config.cwd, function(stdout)
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
  local Binary = require("vibing.core.utils.mote.binary")
  local Command = require("vibing.core.utils.mote.command")
  local Moteignore = require("vibing.core.utils.mote.moteignore")

  if not Binary.is_available() then
    callback(false, "mote binary not found")
    return
  end

  Moteignore.ensure_exists(config.ignore_file)

  local output_dir = vim.fn.fnamemodify(output_path, ":h")
  vim.fn.mkdir(output_dir, "p")

  local cmd = Command.build_base_args(config)
  table.insert(cmd, "diff")
  table.insert(cmd, "-o")
  table.insert(cmd, output_path)

  Command.run(cmd, config.cwd, function()
    callback(true, nil)
  end, function(error)
    callback(false, error)
  end)
end

return M
