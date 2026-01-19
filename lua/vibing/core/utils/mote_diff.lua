---@class Vibing.Utils.MoteDiff
---mote diff表示のユーティリティ
local M = {}

---プラットフォームに応じたmoteバイナリパスを取得
---@return string|nil moteバイナリのパス（見つからない場合nil）
function M.get_mote_path()
  -- まずPATHからmoteを探す
  if vim.fn.executable("mote") == 1 then
    return "mote"
  end

  -- vibing.nvim同梱のmoteバイナリを探す
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(script_path, ":h:h:h:h")

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
  if not platform_key then
    return nil
  end

  local bundled_mote = plugin_root .. "/bin/mote-" .. platform_key
  if vim.fn.executable(bundled_mote) == 1 then
    return bundled_mote
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
---@return boolean moteが初期化されている場合true
function M.is_initialized(cwd)
  cwd = cwd or vim.fn.getcwd()
  local mote_dir = vim.fn.finddir(".mote", cwd .. ";")
  local git_mote_dir = vim.fn.finddir(".git/mote", cwd .. ";")
  return mote_dir ~= "" or git_mote_dir ~= ""
end

---mote diffコマンドを実行してdiffを取得
---@param file_path string ファイルパス（絶対パス）
---@param config Vibing.MoteConfig mote設定
---@param callback fun(success: boolean, output: string?, error: string?) コールバック関数
function M.get_diff(file_path, config, callback)
  local mote_path = M.get_mote_path()
  if not mote_path then
    callback(false, nil, "mote binary not found")
    return
  end

  local normalized_path = vim.fn.fnamemodify(file_path, ":p")

  -- moteのグローバルオプションは必ずサブコマンドの前に指定
  local cmd = {
    mote_path,
    "--ignore-file",
    config.ignore_file,
    "--storage-dir",
    config.storage_dir,
    "diff",
    normalized_path,
  }

  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local error_msg = obj.stderr or "Unknown error"
        callback(false, nil, error_msg)
        return
      end

      local output = obj.stdout or ""
      callback(true, output, nil)
    end)
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

return M
