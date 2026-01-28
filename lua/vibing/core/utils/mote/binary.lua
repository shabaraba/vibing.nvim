---@class Vibing.Utils.Mote.Binary
---moteバイナリの検出とパス管理
local M = {}

---プラットフォームとアーキテクチャの組み合わせからバイナリ名を取得するマップ
local PLATFORM_MAP = {
  ["darwin-arm64"] = "darwin-arm64",
  ["darwin-aarch64"] = "darwin-arm64",
  ["darwin-x86_64"] = "darwin-x64",
  ["linux-aarch64"] = "linux-arm64",
  ["linux-x86_64"] = "linux-x64",
}

---プラグインルートディレクトリを取得
---@return string プラグインルートパス
local function get_plugin_root()
  local script_path = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(script_path, ":h:h:h:h:h:h")
end

---プラットフォームキーを取得
---@return string|nil プラットフォームキー（対応していない場合nil）
local function get_platform_key()
  local platform = vim.loop.os_uname().sysname:lower()
  local arch = vim.loop.os_uname().machine:lower()
  return PLATFORM_MAP[platform .. "-" .. arch]
end

---vibing.nvim同梱のmoteバイナリパスを取得
---@return string|nil 同梱バイナリのパス（見つからない場合nil）
local function get_bundled_mote_path()
  local platform_key = get_platform_key()
  if not platform_key then
    return nil
  end

  local bundled_mote = get_plugin_root() .. "/bin/mote-" .. platform_key
  if vim.fn.executable(bundled_mote) == 1 then
    return bundled_mote
  end

  return nil
end

---プラットフォームに応じたmoteバイナリパスを取得
---vibing.nvim同梱のバイナリを優先的に使用し、見つからない場合のみPATHから探す
---@return string|nil moteバイナリのパス（見つからない場合nil）
function M.get_path()
  local bundled = get_bundled_mote_path()
  if bundled then
    return bundled
  end

  if vim.fn.executable("mote") == 1 then
    return "mote"
  end

  return nil
end

---moteが利用可能かチェック
---@return boolean moteが実行可能な場合true
function M.is_available()
  return M.get_path() ~= nil
end

return M
