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


---ヘッダー行からロールを抽出（HTMLコメント形式/レガシー対応/Squad-aware対応/Mention対応）
---@param line string ヘッダー行
---@return string? role "user" | "assistant" | "mention_from" | "mention_response" | nil（ヘッダーでない場合はnil）
function M.extract_role(line)
  -- 未送信ユーザーヘッダー: "## User <!-- unsent -->"
  if M.is_unsent_user_header(line) then
    return "user"
  end

  -- HTMLコメント形式タイムスタンプ: "## User <!-- YYYY-MM-DD HH:MM:SS -->"
  if M.is_timestamped_user_header(line) then
    return "user"
  end

  -- Mention from Squad header: "## Mention from <Commander> <!-- YYYY-MM-DD HH:MM:SS -->"
  if M.is_mention_from_header(line) then
    return "mention_from"
  end

  -- Mention response header: "## Mention response from <Alpha> <!-- YYYY-MM-DD HH:MM:SS -->"
  if M.is_mention_response_header(line) then
    return "mention_response"
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

---Mention from ヘッダーを作成
---@param squad_name string 送信元のSquad名（例: "Commander", "Alpha"）
---@param timestamp? string オプションのタイムスタンプ（省略時は現在時刻）
---@return string header Mention fromヘッダー（例: "## Mention from <Commander> <!-- 2025-12-29 14:30:55 -->"）
function M.create_mention_from_header(squad_name, timestamp)
  timestamp = timestamp or M.now()
  return string.format("## Mention from <%s> <!-- %s -->", squad_name, timestamp)
end

---Mention response from ヘッダーを作成
---@param squad_name string 返信元のSquad名（例: "Alpha", "Bravo"）
---@param timestamp? string オプションのタイムスタンプ（省略時は現在時刻）
---@return string header Mention response fromヘッダー（例: "## Mention response from <Alpha> <!-- 2025-12-29 14:30:55 -->"）
function M.create_mention_response_header(squad_name, timestamp)
  timestamp = timestamp or M.now()
  return string.format("## Mention response from <%s> <!-- %s -->", squad_name, timestamp)
end

---行がMention fromヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_mention_from Mention fromヘッダーの場合true
function M.is_mention_from_header(line)
  return line:match("^## Mention from <[%w%-]+> <!%-%- " .. TIMESTAMP_PATTERN .. " %-%->$") ~= nil
end

---行がMention response fromヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_mention_response Mention response fromヘッダーの場合true
function M.is_mention_response_header(line)
  return line:match("^## Mention response from <[%w%-]+> <!%-%- " .. TIMESTAMP_PATTERN .. " %-%->$") ~= nil
end

---Mention fromヘッダーからSquad名を抽出
---@param line string Mention fromヘッダー行
---@return string? squad_name Squad名（抽出できない場合はnil）
function M.extract_squad_from_mention_from(line)
  local squad_name = line:match("^## Mention from <([%w%-]+)> <!%-%- " .. TIMESTAMP_PATTERN .. " %-%->$")
  return squad_name
end

---Mention response fromヘッダーからSquad名を抽出
---@param line string Mention response fromヘッダー行
---@return string? squad_name Squad名（抽出できない場合はnil）
function M.extract_squad_from_mention_response(line)
  local squad_name = line:match("^## Mention response from <([%w%-]+)> <!%-%- " .. TIMESTAMP_PATTERN .. " %-%->$")
  return squad_name
end

return M
