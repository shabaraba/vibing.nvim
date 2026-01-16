---タイムスタンプユーティリティ
---チャットメッセージのヘッダーにタイムスタンプを追加・パースする機能を提供

---@class Vibing.Utils.Timestamp
local M = {}

-- タイムスタンプフォーマット定数
local TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S"
-- タイムスタンプパターン（正規表現）
local TIMESTAMP_PATTERN = "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d"
-- レガシーヘッダーパターン（タイムスタンプなし）
local LEGACY_HEADER_PATTERN = "^## (%w+)"

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


---ヘッダー行からロールを抽出（HTMLコメント形式/レガシー対応/Squad-aware対応）
---@param line string ヘッダー行
---@return string? role "user" | "assistant" | nil（ヘッダーでない場合はnil）
function M.extract_role(line)
  -- 未送信ユーザーヘッダー: "## User <!-- unsent -->"
  if M.is_unsent_user_header(line) then
    return "user"
  end

  -- HTMLコメント形式タイムスタンプ: "## User <!-- YYYY-MM-DD HH:MM:SS -->"
  if M.is_timestamped_user_header(line) then
    return "user"
  end

  -- Squad-aware Assistantヘッダー: "## Assistant <Alpha>" or "## Assistant <Commander>"
  if line:match("^## Assistant <[%w%-]+>") then
    return "assistant"
  end

  -- レガシーパターン（シンプルヘッダー）: "## User" or "## Assistant"
  local role = line:match(LEGACY_HEADER_PATTERN)
  if role then
    local lower_role = role:lower()
    -- "user" または "assistant" のみ有効なロールとして認識
    if lower_role == "user" or lower_role == "assistant" then
      return lower_role
    end
  end

  return nil
end


---行がメッセージヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_header ヘッダーの場合true
function M.is_header(line)
  return M.extract_role(line) ~= nil
end


---未送信ユーザーヘッダーを作成
---送信前の一時的なマーカーとして使用され、送信時にタイムスタンプ付きヘッダーに置き換えられる
---@return string header 未送信ユーザーヘッダー（例: "## User <!-- unsent -->"）
function M.create_unsent_user_header()
  return "## User <!-- unsent -->"
end

---タイムスタンプ付きユーザーヘッダーを作成（HTMLコメント形式）
---@param timestamp? string オプションのタイムスタンプ（省略時は現在時刻）
---@return string header タイムスタンプ付きヘッダー（例: "## User <!-- 2025-12-29 14:30:55 -->"）
function M.create_user_header_with_timestamp(timestamp)
  timestamp = timestamp or M.now()
  return string.format("## User <!-- %s -->", timestamp)
end

---行が未送信ユーザーヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_unsent 未送信ヘッダーの場合true
function M.is_unsent_user_header(line)
  return line:match("^## User <!%-%- unsent %-%->$") ~= nil
end

---行がタイムスタンプ付きユーザーヘッダー（HTMLコメント形式）かどうかチェック
---@param line string チェック対象の行
---@return boolean is_timestamped タイムスタンプ付きヘッダーの場合true
function M.is_timestamped_user_header(line)
  return line:match("^## User <!%-%- " .. TIMESTAMP_PATTERN .. " %-%->$") ~= nil
end

---ヘッダーからタイムスタンプを抽出（HTMLコメント形式）
---@param line string タイムスタンプ付きヘッダー行
---@return string? timestamp タイムスタンプ文字列（存在しない場合はnil）
function M.extract_timestamp_from_comment(line)
  local timestamp = line:match("^## User <!%-%- (" .. TIMESTAMP_PATTERN .. ") %-%->$")
  return timestamp
end

return M
