---タイムスタンプユーティリティ
---チャットメッセージのヘッダーにタイムスタンプを追加・パースする機能を提供

---@class Vibing.Utils.Timestamp
local M = {}

-- タイムスタンプフォーマット定数
local TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S"
-- タイムスタンプパターン（正規表現）
local TIMESTAMP_PATTERN = "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d"
-- タイムスタンプ付きヘッダーパターン
local HEADER_WITH_TIMESTAMP_PATTERN = "^## (" .. TIMESTAMP_PATTERN .. ") (%w+)"
-- レガシーヘッダーパターン（タイムスタンプなし）
local LEGACY_HEADER_PATTERN = "^## (%w+)"
-- ヘッダー検出パターン
local TIMESTAMP_CHECK_PATTERN = "^## " .. TIMESTAMP_PATTERN .. " %w+"

---現在時刻のタイムスタンプを生成
---フォーマット: "YYYY-MM-DD HH:MM:SS"
---@return string timestamp フォーマット済みタイムスタンプ文字列
function M.now()
  local timestamp = os.date(TIMESTAMP_FORMAT)
  if not timestamp then
    -- os.date()が失敗した場合（極めて稀だが可能性はある）
    vim.notify("[vibing] Failed to generate timestamp - using fallback", vim.log.levels.WARN)
    -- フォールバック: エポック秒を使用
    return string.format("UNKNOWN-%d", os.time())
  end
  return timestamp
end

---タイムスタンプ付きヘッダーを作成
---@param role "User"|"Assistant" メッセージロール
---@param timestamp? string オプションのタイムスタンプ（省略時は現在時刻）
---@return string header タイムスタンプ付きヘッダー（例: "## 2025-12-27 11:00:13 User"）
function M.create_header(role, timestamp)
  if not role or (role ~= "User" and role ~= "Assistant") then
    local msg = string.format("[vibing] Invalid role for header: %s (expected 'User' or 'Assistant')", tostring(role))
    vim.notify(msg, vim.log.levels.ERROR)
    error(msg)
  end

  timestamp = timestamp or M.now()
  return string.format("## %s %s", timestamp, role)
end

---ヘッダー行からロールを抽出（タイムスタンプあり/なし両対応）
---@param line string ヘッダー行
---@return string? role "user" | "assistant" | nil（ヘッダーでない場合はnil）
function M.extract_role(line)
  -- タイムスタンプ付きパターン: "## YYYY-MM-DD HH:MM:SS User"
  local _, role = line:match(HEADER_WITH_TIMESTAMP_PATTERN)
  if role then
    return role:lower()
  end

  -- レガシーパターン（タイムスタンプなし）: "## User"
  role = line:match(LEGACY_HEADER_PATTERN)
  if role then
    local lower_role = role:lower()
    -- "user" または "assistant" のみ有効なロールとして認識
    if lower_role == "user" or lower_role == "assistant" then
      return lower_role
    end
  end

  return nil
end

---ヘッダー行にタイムスタンプが含まれているか確認
---@param line string チェック対象の行
---@return boolean has_timestamp タイムスタンプが含まれている場合true
function M.has_timestamp(line)
  return line:match(TIMESTAMP_CHECK_PATTERN) ~= nil
end

---ヘッダー行からタイムスタンプを抽出
---@param line string タイムスタンプ付きヘッダー行
---@return string? timestamp タイムスタンプ文字列（存在しない場合はnil）
function M.extract_timestamp(line)
  local timestamp = line:match(HEADER_WITH_TIMESTAMP_PATTERN)
  return timestamp
end

---行がメッセージヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_header ヘッダーの場合true
function M.is_header(line)
  return M.extract_role(line) ~= nil
end

---タイムスタンプセパレーターを作成
---常に完全フォーマット（日付 + 時刻）で生成
---@return string separator セパレーター行（例: "─── 2025-12-28 14:30 ───"）
function M.create_separator()
  local now = os.time()
  local date_part = os.date("%Y-%m-%d", now)
  local time_part = os.date("%H:%M", now)

  return string.format("─── %s %s ───", date_part, time_part)
end

---行がタイムスタンプセパレーターかどうかチェック
---@param line string チェック対象の行
---@return boolean is_separator セパレーターの場合true
function M.is_separator(line)
  -- "─── HH:MM ───" または "─── YYYY-MM-DD HH:MM ───" にマッチ
  return line:match("^───.*───$") ~= nil
end

return M
