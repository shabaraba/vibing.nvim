---@class Vibing.Remote
---Neovimリモートコントロールモジュール
-----listen/--serverソケットを介して別のNeovimインスタンスを制御
---Agent SDKから別ウィンドウのNeovimを操作する際に使用
local M = {}
local notify = require("vibing.utils.notify")

---リモート制御用のソケットパス
---nvim --listen=/path/to/socket で起動時に設定されるパス
---@type string?
M.socket_path = nil

---リモートコントロールを初期化
---socket_pathが指定された場合は直接設定、省略時はNVIM環境変数から自動検出
---NVIMが未設定の場合はリモート機能は無効になる
---@param socket_path? string ソケットパス（省略時は$NVIM環境変数を使用）
function M.setup(socket_path)
  if socket_path then
    M.socket_path = socket_path
  else
    -- Auto-detect from environment variable
    M.socket_path = vim.env.NVIM
  end
end

---リモートコントロールが利用可能かチェック
---socket_pathが設定されている場合のみtrue
---@return boolean ソケットパスが有効な場合true
function M.is_available()
  return M.socket_path ~= nil and M.socket_path ~= ""
end

---リモートNeovimインスタンスにキー入力を送信
---nvim --server --remote-sendを使用してキーシーケンスを送信
---ノーマルモードコマンド、挿入モードテキスト、特殊キー（<CR>, <Esc>等）に対応
---@param keys string 送信するキーシーケンス（例: "iHello<Esc>", ":w<CR>"）
---@return boolean 送信成功時true、ソケット未設定やシステムエラー時false
function M.send(keys)
  if not M.is_available() then
    notify.error("Remote control not available. Set socket_path or start nvim with --listen", "Remote")
    return false
  end

  local cmd = string.format('nvim --server "%s" --remote-send "%s"', M.socket_path, keys)
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    notify.error("Remote send failed: " .. result, "Remote")
    return false
  end

  return true
end

---リモートNeovimインスタンスで式を評価
---nvim --server --remote-exprを使用してVim式を評価し結果を取得
---カーソル位置、バッファ内容、変数値の取得に使用
---@param expr string 評価するVim式（例: "line('.')", "getline(1, '$')"）
---@return string? 評価結果（トリム済み文字列）、エラー時はnil
function M.expr(expr)
  if not M.is_available() then
    notify.error("Remote control not available", "Remote")
    return nil
  end

  local cmd = string.format('nvim --server "%s" --remote-expr "%s"', M.socket_path, expr)
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    notify.error("Remote expr failed: " .. result, "Remote")
    return nil
  end

  return vim.trim(result)
end

---リモートNeovimインスタンスでExコマンドを実行
---ダブルクォートをエスケープし、コロンとCRで囲んでsend()に委譲
---ファイル保存、バッファ切り替え等のコマンド実行に使用
---@param command string 実行するExコマンド（コロンなし、例: "write", "edit foo.lua"）
---@return boolean 実行成功時true、送信エラー時false
function M.execute(command)
  -- Escape special characters
  command = command:gsub('"', '\\"')
  return M.send(string.format(':%s<CR>', command))
end

---リモートバッファの全内容を取得
---getline(1, "$")を評価してVimリスト形式（['line1', 'line2']）をパース
---Agent SDKがファイル内容を読み取る際に使用
---@return string[]? バッファの全行配列、取得失敗時はnil
function M.get_buffer()
  local result = M.expr('getline(1, "$")')
  if not result then
    return nil
  end

  -- Parse Vim list format: ['line1', 'line2', ...]
  local lines = {}
  for line in result:gmatch("'([^']*)'") do
    table.insert(lines, line)
  end

  return lines
end

---リモートNeovimの現在状態を取得
---モード、バッファ名、カーソル位置（行・列）を含むステータステーブルを返す
---Agent SDKがNeovimの状態を把握する際に使用
---@return table? ステータステーブル {mode: string, bufname: string, line: number, col: number}、取得失敗時はnil
function M.get_status()
  if not M.is_available() then
    return nil
  end

  local mode = M.expr('mode()')
  local bufname = M.expr('bufname("%")')
  local line = M.expr('line(".")')
  local col = M.expr('col(".")')

  if not mode then
    return nil
  end

  return {
    mode = mode,
    bufname = bufname or "",
    line = tonumber(line) or 0,
    col = tonumber(col) or 0,
  }
end

return M
